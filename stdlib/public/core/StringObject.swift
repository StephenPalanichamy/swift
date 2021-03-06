//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// TODO: Comments. Supposed to abstract bit-twiddling operations. Meant to be a
// completely transparent struct. That is, it's just a trivial encapsulation to
// host many operations that would otherwise be scattered throughout StringGuts
// implementation.
//
@_fixed_layout
public // @testable
struct _StringObject {
  // TODO: Proper built-in string object support.
#if arch(i386) || arch(arm)
  // BridgeObject lacks support for tagged pointers on 32-bit platforms, and
  // there are no free bits available to implement it.  We use a single-word
  // enum instead, with an additional word for holding tagged values and (in the
  // non-tagged case) spilled flags.
  @_frozen
  @usableFromInline
  internal enum _Variant {
    case strong(AnyObject) // _bits stores flags
    case unmanagedSingleByte // _bits is the start address
    case unmanagedDoubleByte // _bits is the start address
    case smallSingleByte // _bits is the payload
    case smallDoubleByte // _bits is the payload
    // TODO small strings
  }

  @usableFromInline
  internal
  var _variant: _Variant

  @usableFromInline
  internal
  var _bits: UInt
#else
  // On 64-bit platforms, we use BridgeObject for now.  This might be very
  // slightly suboptimal and different than hand-optimized bit patterns, but
  // provides us the runtime functionality we want.
  @usableFromInline
  internal
  var _object: Builtin.BridgeObject
#endif

#if arch(i386) || arch(arm)
  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init(_ variant: _Variant, _ bits: UInt) {
    self._variant = variant
    self._bits = bits
    _invariantCheck()
  }
#else
  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init(_ object: Builtin.BridgeObject) {
    self._object = object
    _invariantCheck()
  }
#endif
}

extension _StringObject {
#if arch(i386) || arch(arm)
  public typealias _RawBitPattern = UInt64
#else
  public typealias _RawBitPattern = UInt
#endif

  @usableFromInline
  @inlinable
  internal
  var rawBits: _RawBitPattern {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      let variantBits: UInt = Builtin.reinterpretCast(_variant)
      return _RawBitPattern(_bits) &<< 32 | _RawBitPattern(variantBits)
#else
      return Builtin.reinterpretCast(_object)
#endif
    }
  }

  @usableFromInline
  @inlinable
  @inline(__always)
  // TODO: private
  internal
  init(taggedRawBits: _RawBitPattern) {
#if arch(i386) || arch(arm)
    self.init(
      Builtin.reinterpretCast(UInt(truncatingIfNeeded: taggedRawBits)),
      UInt(truncatingIfNeeded: taggedRawBits &>> 32))
#else
    self.init(_bridgeObject(fromTagged: taggedRawBits))
    _sanityCheck(self.isValue)
#endif
  }

  @usableFromInline
  @inlinable
  @inline(__always)
  // TODO: private
  internal
  init(nonTaggedRawBits: _RawBitPattern) {
#if arch(i386) || arch(arm)
    self.init(
      Builtin.reinterpretCast(UInt(truncatingIfNeeded: nonTaggedRawBits)),
      UInt(truncatingIfNeeded: nonTaggedRawBits &>> 32))
#else
    self.init(Builtin.reinterpretCast(nonTaggedRawBits))
    _sanityCheck(!self.isValue)
#endif
  }

  // For when you need to hack around ARC. Note that by using this initializer,
  // we are giving up on compile-time constant folding of ARC of values. Thus,
  // this should only be called from the callee of a non-inlineable function
  // that has no knowledge of the value-ness of the object.
  @usableFromInline
  @inlinable
  @inline(__always)
  // TODO: private
  internal
  init(noReallyHereAreTheRawBits bits: _RawBitPattern) {
#if arch(i386) || arch(arm)
    self.init(
      Builtin.reinterpretCast(UInt(truncatingIfNeeded: bits)),
      UInt(truncatingIfNeeded: bits &>> 32))
#else
    self.init(Builtin.reinterpretCast(bits))
#endif
  }
}

// ## _StringObject bit layout
//
// x86-64 and arm64: (one 64-bit word)
// +---+---+---|---+------+----------------------------------------------------+
// + t | v | o | w | uuuu | payload (56 bits)                                  |
// +---+---+---|---+------+----------------------------------------------------+
//  msb                                                                     lsb
//
// i386 and arm: (two 32-bit words)
// _variant                               _bits
// +------------------------------------+ +------------------------------------+
// + .strong(AnyObject)                 | | v | o | w | unused (29 bits)       |
// +------------------------------------+ +------------------------------------+
// + .unmanaged{Single,Double}Byte      | | start address (32 bits)            |
// +------------------------------------+ +------------------------------------+
// + .small{Single,Double}Byte          | | payload (32 bits)                  |
// +------------------------------------+ +------------------------------------+
//  msb                              lsb   msb                              lsb
//
// where t: is-a-value, i.e. a tag bit that says not to perform ARC
//       v: sub-variant bit, i.e. set for isCocoa or isSmall
//       o: is-opaque, i.e. opaque vs contiguously stored strings
//       w: width indicator bit (0: ASCII, 1: UTF-16)
//       u: unused bits
//
// payload is:
//   isNative: the native StringStorage object
//   isCocoa: the Cocoa object
//   isOpaque & !isCocoa: the _OpaqueString object
//   isUnmanaged: the pointer to code units
//   isSmall: opaque bits used for inline storage // TODO: use them!
//
extension _StringObject {
#if arch(i386) || arch(arm)
  @usableFromInline
  @inlinable
  internal
  static var _isCocoaBit: UInt {
    @inline(__always)
    get {
      return 0x8000_0000
    }
  }

  @usableFromInline
  @inlinable
  internal
  static var _isOpaqueBit: UInt {
    @inline(__always)
    get {
      return 0x4000_0000
    }
  }

  @usableFromInline
  @inlinable
  internal
  static var _twoByteBit: UInt {
    @inline(__always)
    get {
      return 0x2000_0000
    }
  }
#else // !(arch(i386) || arch(arm))
  @usableFromInline
  @inlinable
  internal
  static var _isValueBit: UInt {
    @inline(__always)
    get {
      // NOTE: deviating from ObjC tagged pointer bits, as we just want to avoid
      // swift runtime management, and top bit suffices for that.
      return 0x80_00_0000_0000_0000
    }
  }

  // After deciding isValue, which of the two variants (on both sides) are we.
  // That is, native vs objc or unsafe vs small.
  @usableFromInline
  @inlinable
  internal
  static var _subVariantBit: UInt {
    @inline(__always)
    get {
      return 0x40_00_0000_0000_0000
    }
  }

  @usableFromInline
  @inlinable
  internal
  static var _isOpaqueBit: UInt {
    @inline(__always)
    get {
      return 0x20_00_0000_0000_0000
    }
  }

  @usableFromInline
  @inlinable
  internal
  static var _twoByteBit: UInt {
    @inline(__always)
    get {
      return 0x10_00_0000_0000_0000
    }
  }

  // There are 4 sub-variants depending on the isValue and subVariant bits
  @usableFromInline
  @inlinable
  internal
  static var _variantMask: UInt {
    @inline(__always)
    get { return UInt(Builtin.stringObjectOr_Int64(
      _isValueBit._value, _subVariantBit._value)) }
  }

  @usableFromInline
  @inlinable
  internal
  static var _payloadMask: UInt {
    @inline(__always)
    get {
      return 0x00FF_FFFF_FFFF_FFFF
    }
  }

  @usableFromInline
  @inlinable
  internal
  var _variantBits: UInt {
    @inline(__always)
    get {
      return rawBits & _StringObject._variantMask
    }
  }
#endif // arch(i386) || arch(arm)

  @usableFromInline
  @inlinable
  internal
  var referenceBits: UInt {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      guard case let .strong(object) = _variant else {
        _sanityCheckFailure("internal error: expected a non-tagged String")
      }
      return Builtin.reinterpretCast(object)
#else
      _sanityCheck(isNative || isCocoa)
      return rawBits & _StringObject._payloadMask
#endif
    }
  }

  @usableFromInline
  @inlinable
  internal
  var payloadBits: UInt {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      if case .strong(_) = _variant {
        _sanityCheckFailure("internal error: expected a tagged String")
      }
      return _bits
#else
      _sanityCheck(!isNative && !isCocoa)
      return rawBits & _StringObject._payloadMask
#endif
    }
  }
}

//
// Empty strings
//

#if arch(i386) || arch(arm)
internal var _emptyStringStorage: UInt32 = 0

// NB: This function *cannot* be @inlinable because it expects to project
// and escape the physical storage of `_emptyStringStorage`.
// Marking it inlinable will cause it to resiliently use accessors to
// project `_emptyStringStorage` as a computed
// property.
@usableFromInline // FIXME(sil-serialize-all)
internal var _emptyStringAddressBits: UInt {
  let p = UnsafeRawPointer(Builtin.addressof(&_emptyStringStorage))
  return UInt(bitPattern: p)
}
#endif // arch(i386) || arch(arm)

extension _StringObject {
#if arch(i386) || arch(arm)
  @usableFromInline
  @inlinable
  internal
  var isEmptySingleton: Bool {
    guard _bits == _emptyStringAddressBits else { return false }
    switch _variant {
    case .unmanagedSingleByte, .unmanagedDoubleByte:
      return true
    default:
      return false
    }
  }

  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init() {
    self.init(.unmanagedSingleByte, _emptyStringAddressBits)
  }
#else
  @usableFromInline
  @inlinable
  internal
  static var _emptyStringBitPattern: UInt {
    @inline(__always)
    get {  return _smallUTF8TopNibble }
  }

  @usableFromInline
  @inlinable
  internal
  var isEmptySingleton: Bool {
    @inline(__always)
    get { return rawBits == _StringObject._emptyStringBitPattern }
  }

  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init() {
    self.init(taggedRawBits: _StringObject._emptyStringBitPattern)
  }
#endif
}

//
// Small strings
//
extension _StringObject {
  // TODO: Decide what to do for the last bit in the top nibble, when we scrap
  // the opaque bit (which should really be the isSmallUTF8String bit)
  //
  // TODO: Pretty ASCII art, better description
  //
  // An encoded small UTF-8 string's first byte has a leading nibble of 1110
  // and a trailing nibble containing the count.

#if arch(i386) || arch(arm)
#else
  @usableFromInline @inlinable internal
  static var _topNibbleMask: UInt {
    @inline(__always)
    get { return 0xF000_0000_0000_0000 }
  }
  @usableFromInline @inlinable internal
  static var _smallUTF8TopNibble: UInt {
    @inline(__always)
    get { return 0xE000_0000_0000_0000 }
  }
  @usableFromInline @inlinable internal
  static var _smallUTF8CountMask: UInt {
    @inline(__always)
    get { return 0x0F00_0000_0000_0000 }
  }
#endif

  @usableFromInline
  @inlinable
  internal
  var _isSmallUTF8: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      return false
#else
      return rawBits & _StringObject._topNibbleMask
        == _StringObject._smallUTF8TopNibble
#endif
    }
  }

  // TODO: describe better
  //
  // The top nibble is the mask, second nibble the count. Turn off the mask and
  // keep the count. The StringObject represents the second word of a
  // SmallUTF8String.
  //
  @usableFromInline
  @inlinable
  internal
  var asSmallUTF8SecondWord: UInt {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      unsupportedOn32bit()
#else
      _sanityCheck(_isSmallUTF8)
      return rawBits & ~_StringObject._topNibbleMask
#endif
    }
  }

  @usableFromInline
  @inlinable
  internal
  var smallUTF8Count: Int {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      unsupportedOn32bit()
#else
      _sanityCheck(_isSmallUTF8)
      let count = (rawBits & _StringObject._smallUTF8CountMask) &>> 56
      _sanityCheck(count <= _SmallUTF8String.capacity)
      return Int(bitPattern: count)
#endif
    }
  }

  @usableFromInline
  @inlinable
  internal
  init(_smallUTF8SecondWord bits: UInt) {
#if arch(i386) || arch(arm)
      unsupportedOn32bit()
#else
    _sanityCheck(bits & _StringObject._topNibbleMask == 0)
    self.init(taggedRawBits: bits | _StringObject._smallUTF8TopNibble)
#endif
  }
}

//
// Private convenience helpers to layer on top of BridgeObject
//
// TODO: private!
//
extension _StringObject {
  @usableFromInline
  @inlinable
  internal // TODO: private!
  var asNativeObject: AnyObject {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      switch _variant {
      case .strong(let object):
        _sanityCheck(_bits & _StringObject._isCocoaBit == 0)
        _sanityCheck(_usesNativeSwiftReferenceCounting(type(of: object)))
        return object
      default:
        _sanityCheckFailure("asNativeObject on unmanaged _StringObject")
      }
#else
      _sanityCheck(isNative)
      _sanityCheck(
        _usesNativeSwiftReferenceCounting(
          type(of: Builtin.reinterpretCast(referenceBits) as AnyObject)))
      return Builtin.reinterpretCast(referenceBits)
#endif
    }
  }

#if _runtime(_ObjC)
  @usableFromInline
  @inlinable
  internal // TODO: private!
  var asCocoaObject: _CocoaString {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      switch _variant {
      case .strong(let object):
        _sanityCheck(_bits & _StringObject._isCocoaBit != 0)
        _sanityCheck(!_usesNativeSwiftReferenceCounting(type(of: object)))
        return object
      default:
        _sanityCheckFailure("asCocoaObject on unmanaged _StringObject")
      }
#else
      _sanityCheck(isCocoa)
      _sanityCheck(
        !_usesNativeSwiftReferenceCounting(
          type(of: Builtin.reinterpretCast(referenceBits) as AnyObject)))
      return Builtin.reinterpretCast(referenceBits)
#endif
    }
  }
#endif

  @usableFromInline
  @inlinable
  internal // TODO: private!
  var asOpaqueObject: _OpaqueString {
    @inline(__always)
    get {
      _sanityCheck(isOpaque)
      let object = Builtin.reinterpretCast(referenceBits) as AnyObject
      return object as! _OpaqueString
    }
  }

  @usableFromInline
  @inlinable
  internal
  var asUnmanagedRawStart: UnsafeRawPointer {
    @inline(__always)
    get {
      _sanityCheck(isUnmanaged)
#if arch(i386) || arch(arm)
      return UnsafeRawPointer(bitPattern: _bits)._unsafelyUnwrappedUnchecked
#else
      return UnsafeRawPointer(
        bitPattern: payloadBits
      )._unsafelyUnwrappedUnchecked
#endif
    }
  }
}

//
// Queries on a StringObject
//
extension _StringObject {
  //
  // Determine which of the 4 major variants we are
  //
  @usableFromInline
  @inlinable
  internal
  var isNative: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      guard case .strong(_) = _variant else { return false }
      return _bits & _StringObject._isCocoaBit == 0
#else
      return _variantBits == 0
#endif
    }
  }

  @usableFromInline
  @inlinable
  internal
  var isCocoa: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      guard case .strong(_) = _variant else { return false }
      return _bits & _StringObject._isCocoaBit != 0
#else
      return _variantBits == _StringObject._subVariantBit
#endif
    }
  }

  public // @testable
  var owner: AnyObject? { // For testing only
#if arch(i386) || arch(arm)
    guard case .strong(let object) = _variant else { return nil }
    return object
#else
    if _fastPath(isNative || isCocoa) {
      return Builtin.reinterpretCast(referenceBits)
    }
    return nil
#endif
  }

  @usableFromInline
  @inlinable
  internal
  var isValue: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      switch _variant {
      case .strong(_): return false
      default:
        return true
      }
#else
      return rawBits & _StringObject._isValueBit != 0
#endif
    }
  }

  @usableFromInline
  @inlinable
  internal
  var isUnmanaged: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      switch _variant {
      case .unmanagedSingleByte, .unmanagedDoubleByte:
        return true
      default:
        return false
      }
#else
      return _variantBits == _StringObject._isValueBit
#endif
    }
  }

  @usableFromInline
  @inlinable
  internal
  var isSmall: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      switch _variant {
      case .smallSingleByte, .smallDoubleByte:
        return true
      default:
        return false
      }
#else
      return _variantBits == _StringObject._variantMask
#endif
    }
  }

  @usableFromInline
  @inlinable
  internal
  var isSmallOrCocoa: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      switch _variant {
      case .smallSingleByte, .smallDoubleByte:
        return true
      default:
        return isCocoa
      }
#else
      return rawBits & _StringObject._subVariantBit != 0
#endif
    }
  }

  //
  // Frequently queried properties
  //
  @usableFromInline
  @inlinable
  internal
  var isContiguous: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      switch _variant {
      case .strong(_):
        return _bits & _StringObject._isOpaqueBit == 0
      case .unmanagedSingleByte, .unmanagedDoubleByte:
        return true
      case .smallSingleByte, .smallDoubleByte:
        return false
      }
#else
      return rawBits & _StringObject._isOpaqueBit == 0
#endif
    }
  }

  @usableFromInline
  @inlinable
  internal
  var isOpaque: Bool {
    @inline(__always)
    get { return !isContiguous }
  }

  @usableFromInline
  @inlinable
  internal
  var isContiguousCocoa: Bool {
    @inline(__always)
    get { return isContiguous && isCocoa }
  }

  @usableFromInline
  @inlinable
  internal
  var isNoncontiguousCocoa: Bool {
    @inline(__always)
    get { return isCocoa && isOpaque }
  }

  @inlinable
  public // @testable
  var isSingleByte: Bool {
    @inline(__always)
    get {
#if arch(i386) || arch(arm)
      switch _variant {
      case .strong(_):
        return _bits & _StringObject._twoByteBit == 0
      case .unmanagedSingleByte, .smallSingleByte:
        return true
      case .unmanagedDoubleByte, .smallDoubleByte:
        return false
      }
#else
      return rawBits & _StringObject._twoByteBit == 0
#endif
    }
  }

  @inlinable
  public // @testable
  var byteWidth: Int {
    @inline(__always)
    get { return isSingleByte ? 1 : 2 }
  }

  @usableFromInline
  @inlinable
  var bitWidth: Int {
    @inline(__always)
    get { return byteWidth &<< 3 }
  }

  @inlinable
  public // @testable
  var isContiguousASCII: Bool {
    @inline(__always)
    get { return isContiguous && isSingleByte }
  }

  @inlinable
  public // @testable
  var isContiguousUTF16: Bool {
    @inline(__always)
    get { return isContiguous && !isSingleByte }
  }

  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  func nativeStorage<CodeUnit>(
    of codeUnit: CodeUnit.Type = CodeUnit.self
  ) -> _SwiftStringStorage<CodeUnit>
  where CodeUnit : FixedWidthInteger & UnsignedInteger {
    _sanityCheck(isNative)
    _sanityCheck(CodeUnit.bitWidth == self.bitWidth)
    // TODO: Is this the way to do it?
    return _unsafeUncheckedDowncast(
      asNativeObject, to: _SwiftStringStorage<CodeUnit>.self)
  }

  @inlinable
  public // @testable
  var nativeRawStorage: _SwiftRawStringStorage {
    @inline(__always) get {
      _sanityCheck(isNative)
      return _unsafeUncheckedDowncast(
        asNativeObject, to: _SwiftRawStringStorage.self)
    }
  }
}

extension _StringObject {
  @inlinable // FIXME(sil-serialize-all)
  @usableFromInline // FIXME(sil-serialize-all)
  internal func _invariantCheck() {
#if INTERNAL_CHECKS_ENABLED
    _sanityCheck(MemoryLayout<_StringObject>.size == 8)
    _sanityCheck(isContiguous || isOpaque)
    _sanityCheck(isOpaque || isContiguousASCII || isContiguousUTF16)
    if isNative {
      _sanityCheck(isContiguous)
      if isSingleByte {
        _sanityCheck(isContiguousASCII)
        _sanityCheck(asNativeObject is _SwiftStringStorage<UInt8>)
      } else {
        _sanityCheck(asNativeObject is _SwiftStringStorage<UInt16>)
      }
    } else if isUnmanaged {
      _sanityCheck(isContiguous)
      _sanityCheck(payloadBits > 0) // TODO: inside address space
    } else if isCocoa {
#if _runtime(_ObjC)
      let object = asCocoaObject
      _sanityCheck(
        !_usesNativeSwiftReferenceCounting(type(of: object as AnyObject)))
#else
      _sanityCheckFailure("Cocoa objects aren't supported on this platform")
#endif
    } else if isSmall {
      // TODO: Drop the whole opaque bit thing...
      _sanityCheck(isOpaque)

    } else {
      fatalError("Unimplemented string form")
    }
#endif // INTERNAL_CHECKS_ENABLED
  }
}

//
// Conveniently construct, tag, flag, etc. StringObjects
//
extension _StringObject {
  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init(
    _payloadBits: UInt,
    isValue: Bool,
    isSmallOrObjC: Bool,
    isOpaque: Bool,
    isTwoByte: Bool
  ) {
#if INTERNAL_CHECKS_ENABLED
    defer {
      _sanityCheck(isSmall == (isValue && isSmallOrObjC))
      _sanityCheck(isUnmanaged == (isValue && !isSmallOrObjC))
      _sanityCheck(isCocoa == (!isValue && isSmallOrObjC))
      _sanityCheck(isNative == (!isValue && !isSmallOrObjC))
    }
#endif

#if arch(i386) || arch(arm)
    if isValue {
      if isSmallOrObjC {
        _sanityCheck(isOpaque)
        self.init(isTwoByte ? .smallDoubleByte : .smallSingleByte, _payloadBits)
      } else {
        _sanityCheck(!isOpaque)
        self.init(
          isTwoByte ? .unmanagedDoubleByte : .unmanagedSingleByte, _payloadBits)
      }
      return
    }

    var bits: UInt = 0
    if isSmallOrObjC {
      bits |= _StringObject._isCocoaBit
    }
    if isOpaque {
      bits |= _StringObject._isOpaqueBit
    }
    if isTwoByte {
      bits |= _StringObject._twoByteBit
    }
    self.init(.strong(Builtin.reinterpretCast(_payloadBits)), bits)
#else
    _sanityCheck(_payloadBits & ~_StringObject._payloadMask == 0)
    var rawBits = _payloadBits & _StringObject._payloadMask
    if isValue {
      var rawBitsBuiltin = Builtin.stringObjectOr_Int64(
        rawBits._value, _StringObject._isValueBit._value)
      if isSmallOrObjC {
        rawBitsBuiltin = Builtin.stringObjectOr_Int64(
          rawBitsBuiltin, _StringObject._subVariantBit._value)
      }
      if isOpaque {
        rawBitsBuiltin = Builtin.stringObjectOr_Int64(
          rawBitsBuiltin, _StringObject._isOpaqueBit._value)
      }
      if isTwoByte {
        rawBitsBuiltin = Builtin.stringObjectOr_Int64(
          rawBitsBuiltin, _StringObject._twoByteBit._value)
      }
      rawBits = UInt(rawBitsBuiltin)
      self.init(taggedRawBits: rawBits)
    } else {
      if isSmallOrObjC {
        rawBits |= _StringObject._subVariantBit
      }
      if isOpaque {
        rawBits |= _StringObject._isOpaqueBit
      }
      if isTwoByte {
        rawBits |= _StringObject._twoByteBit
      }
      self.init(nonTaggedRawBits: rawBits)
    }
#endif
  }

  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init(
    _someObject: AnyObject,
    isCocoa: Bool,
    isContiguous: Bool,
    isSingleByte: Bool
  ) {
    defer { _fixLifetime(_someObject) }
    self.init(
      _payloadBits: Builtin.reinterpretCast(_someObject),
      isValue: false,
      isSmallOrObjC: isCocoa,
      isOpaque: !isContiguous,
      isTwoByte: !isSingleByte)
  }

  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init(nativeObject: AnyObject, isSingleByte: Bool) {
    self.init(
      _someObject: nativeObject,
      isCocoa: false,
      isContiguous: true,
      isSingleByte: isSingleByte)
  }

#if _runtime(_ObjC)
  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init(cocoaObject: AnyObject, isSingleByte: Bool, isContiguous: Bool) {
    // TODO: is it possible to sanity check? maybe `is NSObject`?
    self.init(
      _someObject: cocoaObject,
      isCocoa: true,
      isContiguous: isContiguous,
      isSingleByte: isSingleByte)
  }
#else
  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init<S: _OpaqueString>(opaqueString: S) {
    self.init(
      _someObject: opaqueString,
      isCocoa: false,
      isContiguous: false,
      isSingleByte: false)
  }
#endif

  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init<CodeUnit>(
    unmanaged: UnsafePointer<CodeUnit>
  ) where CodeUnit : FixedWidthInteger & UnsignedInteger {
    self.init(
      _payloadBits: UInt(bitPattern: unmanaged),
      isValue: true,
      isSmallOrObjC: false,
      isOpaque: false,
      isTwoByte: CodeUnit.bitWidth == 16)
    _sanityCheck(isSingleByte == (CodeUnit.bitWidth == 8))
  }

  @usableFromInline
  @inlinable
  @inline(__always)
  internal
  init<CodeUnit>(
    _ storage: _SwiftStringStorage<CodeUnit>
  ) where CodeUnit : FixedWidthInteger & UnsignedInteger {
    self.init(nativeObject: storage, isSingleByte: CodeUnit.bitWidth == 8)
    _sanityCheck(isSingleByte == (CodeUnit.bitWidth == 8))
  }
}
