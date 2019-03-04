// Ported from:
//
// https://github.com/llvm/llvm-project/blob/02d85149a05cb1f6dc49f0ba7a2ceca53718ae17/compiler-rt/lib/builtins/fp_add_impl.inc

const std = @import("std");
const builtin = @import("builtin");
const compiler_rt = @import("../compiler_rt.zig");

pub extern fn __addtf3(a: f128, b: f128) f128 {
    return addXf3(f128, a, b);
}

pub extern fn __subtf3(a: f128, b: f128) f128 {
    const neg_b = @bitCast(f128, @bitCast(u128, b) ^ (u128(1) << 127));
    return addXf3(f128, a, neg_b);
}

inline fn normalize(comptime T: type, significand: *@IntType(false, T.bit_count)) i32 {
    const Z = @IntType(false, T.bit_count);
    const significandBits = std.math.floatMantissaBits(T);
    const implicitBit = Z(1) << significandBits;

    const shift = @clz(significand.*) - @clz(implicitBit);
    significand.* <<= @intCast(u7, shift);
    return 1 - shift;
}

inline fn addXf3(comptime T: type, a: T, b: T) T {
    const Z = @IntType(false, T.bit_count);

    const typeWidth = T.bit_count;
    const significandBits = std.math.floatMantissaBits(T);
    const exponentBits = std.math.floatExponentBits(T);

    const signBit = (Z(1) << (significandBits + exponentBits));
    const maxExponent = ((1 << exponentBits) - 1);
    const exponentBias = (maxExponent >> 1);

    const implicitBit = (Z(1) << significandBits);
    const quietBit = implicitBit >> 1;
    const significandMask = implicitBit - 1;

    const absMask = signBit - 1;
    const exponentMask = absMask ^ significandMask;
    const qnanRep = exponentMask | quietBit;

    var aRep = @bitCast(Z, a);
    var bRep = @bitCast(Z, b);
    const aAbs = aRep & absMask;
    const bAbs = bRep & absMask;

    const negative = (aRep & signBit) != 0;
    const exponent = @intCast(i32, aAbs >> significandBits) - exponentBias;
    const significand = (aAbs & significandMask) | implicitBit;

    const infRep = @bitCast(Z, std.math.inf(T));

    // Detect if a or b is zero, infinity, or NaN.
    if (aAbs - Z(1) >= infRep - Z(1) or
        bAbs - Z(1) >= infRep - Z(1))
    {
        // NaN + anything = qNaN
        if (aAbs > infRep) return @bitCast(T, @bitCast(Z, a) | quietBit);
        // anything + NaN = qNaN
        if (bAbs > infRep) return @bitCast(T, @bitCast(Z, b) | quietBit);

        if (aAbs == infRep) {
            // +/-infinity + -/+infinity = qNaN
            if ((@bitCast(Z, a) ^ @bitCast(Z, b)) == signBit) {
                return @bitCast(T, qnanRep);
            }
            // +/-infinity + anything remaining = +/- infinity
            else {
                return a;
            }
        }

        // anything remaining + +/-infinity = +/-infinity
        if (bAbs == infRep) return b;

        // zero + anything = anything
        if (aAbs == 0) {
            // but we need to get the sign right for zero + zero
            if (bAbs == 0) {
                return @bitCast(T, @bitCast(Z, a) & @bitCast(Z, b));
            } else {
                return b;
            }
        }

        // anything + zero = anything
        if (bAbs == 0) return a;
    }

    // Swap a and b if necessary so that a has the larger absolute value.
    if (bAbs > aAbs) {
        const temp = aRep;
        aRep = bRep;
        bRep = temp;
    }

    // Extract the exponent and significand from the (possibly swapped) a and b.
    var aExponent = @intCast(i32, (aRep >> significandBits) & maxExponent);
    var bExponent = @intCast(i32, (bRep >> significandBits) & maxExponent);
    var aSignificand = aRep & significandMask;
    var bSignificand = bRep & significandMask;

    // Normalize any denormals, and adjust the exponent accordingly.
    if (aExponent == 0) aExponent = normalize(T, &aSignificand);
    if (bExponent == 0) bExponent = normalize(T, &bSignificand);

    // The sign of the result is the sign of the larger operand, a.  If they
    // have opposite signs, we are performing a subtraction; otherwise addition.
    const resultSign = aRep & signBit;
    const subtraction = (aRep ^ bRep) & signBit != 0;

    // Shift the significands to give us round, guard and sticky, and or in the
    // implicit significand bit.  (If we fell through from the denormal path it
    // was already set by normalize( ), but setting it twice won't hurt
    // anything.)
    aSignificand = (aSignificand | implicitBit) << 3;
    bSignificand = (bSignificand | implicitBit) << 3;

    // Shift the significand of b by the difference in exponents, with a sticky
    // bottom bit to get rounding correct.
    const @"align" = @intCast(Z, aExponent - bExponent);
    if (@"align" != 0) {
        if (@"align" < typeWidth) {
            const sticky = if (bSignificand << @intCast(u7, typeWidth - @"align") != 0) Z(1) else 0;
            bSignificand = (bSignificand >> @truncate(u7, @"align")) | sticky;
        } else {
            bSignificand = 1; // sticky; b is known to be non-zero.
        }
    }
    if (subtraction) {
        aSignificand -= bSignificand;
        // If a == -b, return +zero.
        if (aSignificand == 0) return @bitCast(T, Z(0));

        // If partial cancellation occured, we need to left-shift the result
        // and adjust the exponent:
        if (aSignificand < implicitBit << 3) {
            const shift = @intCast(i32, @clz(aSignificand)) - @intCast(i32, @clz(implicitBit << 3));
            aSignificand <<= @intCast(u7, shift);
            aExponent -= shift;
        }
    } else { // addition
        aSignificand += bSignificand;

        // If the addition carried up, we need to right-shift the result and
        // adjust the exponent:
        if (aSignificand & (implicitBit << 4) != 0) {
            const sticky = aSignificand & 1;
            aSignificand = aSignificand >> 1 | sticky;
            aExponent += 1;
        }
    }

    // If we have overflowed the type, return +/- infinity:
    if (aExponent >= maxExponent) return @bitCast(T, infRep | resultSign);

    if (aExponent <= 0) {
        // Result is denormal before rounding; the exponent is zero and we
        // need to shift the significand.
        const shift = @intCast(Z, 1 - aExponent);
        const sticky = if (aSignificand << @intCast(u7, typeWidth - shift) != 0) Z(1) else 0;
        aSignificand = aSignificand >> @intCast(u7, shift | sticky);
        aExponent = 0;
    }

    // Low three bits are round, guard, and sticky.
    const roundGuardSticky = aSignificand & 0x7;

    // Shift the significand into place, and mask off the implicit bit.
    var result = (aSignificand >> 3) & significandMask;

    // Insert the exponent and sign.
    result |= @intCast(Z, aExponent) << significandBits;
    result |= resultSign;

    // Final rounding.  The result may overflow to infinity, but that is the
    // correct result in that case.
    if (roundGuardSticky > 0x4) result += 1;
    if (roundGuardSticky == 0x4) result += result & 1;

    return @bitCast(T, result);
}

test "import addXf3" {
    _ = @import("addXf3_test.zig");
}
