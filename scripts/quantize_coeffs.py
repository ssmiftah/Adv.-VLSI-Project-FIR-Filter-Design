#!/usr/bin/env python3
"""
quantize_coeffs.py
------------------
Reads FIR filter coefficients from a CSV file, quantizes them to signed
two's complement fixed-point format, prints quantization statistics, and
generates a self-contained parameterized SystemVerilog ROM (.sv) with the
coefficient values embedded directly in an initial block — no .mem file needed.

Quantization method: Round-to-Nearest with Saturation (Q-format, auto-detected)
  - Determines the minimum number of integer bits needed from the data range.
  - Remaining bits are fractional, maximizing precision.
  - Rounds to nearest integer (unbiased, minimizes MSE).
  - Saturates at [-(2^(N-1)), 2^(N-1)-1] instead of wrapping around.

Usage:
  python quantize_coeffs.py --input coefficients.csv --num_bits 16 --num_taps 100
  python quantize_coeffs.py --input coefficients.csv --num_bits 18 --rom_out ../rtl/coeff_rom.sv

Arguments:
  --input        Path to input CSV file (one coefficient per row, or comma-separated)
  --num_bits     Bit-width for quantized coefficients (default: 16)
  --num_taps     Expected tap count for validation (optional)
  --rom_out      Output SystemVerilog ROM file path (default: ../rtl/coeff_rom.sv)
  --module_name  Verilog module name (default: coeff_rom)
  --skip_header  Skip the first row of the CSV if it is a header (flag)
"""

import csv
import math
import argparse
import os
import sys


# =============================================================================
# CSV Reading
# =============================================================================

def read_csv(filepath, skip_header=False):
    """
    Read floating-point coefficients from a CSV file.
    Supports:
      - One coefficient per row   (single-column)
      - All coefficients in one row (single-row, comma-separated)
      - Mixed / multi-column (reads all numeric cells, row by row)
    Returns a Python list of floats.
    """
    coeffs = []
    with open(filepath, 'r', newline='') as f:
        reader = csv.reader(f)
        for row_idx, row in enumerate(reader):
            if skip_header and row_idx == 0:
                continue
            for cell in row:
                cell = cell.strip()
                if not cell:
                    continue
                try:
                    coeffs.append(float(cell))
                except ValueError:
                    pass   # skip non-numeric cells (stray headers, units, etc.)
    return coeffs


# =============================================================================
# Quantization
# =============================================================================

def detect_q_format(coeffs, num_bits):
    """
    Auto-detect the Q-format that fits all coefficients without clipping.

    For coefficients with max|coeff| < 1.0  ->  Q1.(N-1)
      1 sign bit, N-1 fractional bits, scale = 2^(N-1)

    For larger coefficients, integer bits grow so that max|coeff| fits, and
    the remaining bits are fractional.  int_bits always includes the sign bit.

    Returns (int_bits, frac_bits, scale)  where  scale = 2^frac_bits.
    """
    max_abs = max(abs(c) for c in coeffs)

    if max_abs == 0.0:
        return 1, num_bits - 1, float(1 << (num_bits - 1))

    if max_abs < 1.0:
        int_bits  = 1               # sign bit only
        frac_bits = num_bits - 1
    else:
        # extra integer bits needed above the sign bit
        extra     = math.ceil(math.log2(max_abs + 1e-12))
        int_bits  = extra + 1       # +1 for sign
        frac_bits = num_bits - int_bits
        if frac_bits < 0:
            print(f"ERROR: max|coeff| = {max_abs:.6f} requires {int_bits} bits just for the "
                  f"integer part, which exceeds --num_bits={num_bits}.")
            sys.exit(1)
        if frac_bits == 0:
            print("WARNING: no fractional bits remain — all precision is consumed by the "
                  "integer part. Consider increasing --num_bits.")

    scale = float(1 << frac_bits)
    return int_bits, frac_bits, scale


def quantize_coefficients(coeffs, num_bits):
    """
    Quantize a list of floats to num_bits signed two's complement.

    Steps:
      1. Auto-detect Q-format.
      2. Scale: q_real = coeff * scale
      3. Round to nearest integer (round-half-away-from-zero, no systematic bias).
      4. Saturate to [-(2^(N-1)), 2^(N-1)-1].

    Returns (quantized, scale, frac_bits, int_bits, errors).
    """
    int_bits, frac_bits, scale = detect_q_format(coeffs, num_bits)

    max_val =  (1 << (num_bits - 1)) - 1    #  2^(N-1) - 1
    min_val = -(1 << (num_bits - 1))         # -2^(N-1)

    quantized, errors = [], []
    for c in coeffs:
        scaled = c * scale
        # round-half-away-from-zero
        q = int(scaled + 0.5) if scaled >= 0 else int(scaled - 0.5)
        q = max(min_val, min(max_val, q))   # saturate
        quantized.append(q)
        errors.append(c - q / scale)

    return quantized, scale, frac_bits, int_bits, errors


# =============================================================================
# Statistics
# =============================================================================

def compute_stats(coeffs, quantized, errors, scale, frac_bits, int_bits, num_bits):
    """Print a quantization quality report and return a stats dict."""
    n            = len(coeffs)
    max_abs_err  = max(abs(e) for e in errors)
    rms_err      = math.sqrt(sum(e ** 2 for e in errors) / n)
    signal_power = sum(c ** 2 for c in coeffs) / n
    noise_power  = sum(e ** 2 for e in errors) / n
    snr_db       = 10.0 * math.log10(signal_power / noise_power) if noise_power > 0 else float('inf')
    theo_snr     = 6.02 * num_bits + 1.76

    clipped = sum(
        1 for q in quantized
        if q == (1 << (num_bits - 1)) - 1 or q == -(1 << (num_bits - 1))
    )

    print()
    print("=" * 58)
    print("  Coefficient Quantization Report")
    print("=" * 58)
    print(f"  Taps               : {n}")
    print(f"  Bit-width          : {num_bits} bits (signed two's complement)")
    print(f"  Q format           : Q{int_bits}.{frac_bits}  "
          f"(1 sign + {int_bits-1} integer + {frac_bits} fractional)")
    print(f"  Scale factor       : 2^{frac_bits} = {int(scale)}")
    print(f"  Representable range: [{-(1<<(num_bits-1))}, {(1<<(num_bits-1))-1}]")
    print(f"  Max |coeff|        : {max(abs(c) for c in coeffs):.8f}")
    print(f"  LSB resolution     : {1.0/scale:.2e}")
    print(f"  Max |quant error|  : {max_abs_err:.2e}  (ideal <= {0.5/scale:.2e})")
    print(f"  RMS quant error    : {rms_err:.2e}")
    print(f"  Achieved SNR       : {snr_db:.2f} dB")
    print(f"  Theoretical max    : {theo_snr:.2f} dB  (6.02 x {num_bits} + 1.76)")
    if clipped:
        print(f"\n  *** WARNING: {clipped} coefficient(s) saturated at boundary! ***")
        print(f"      Consider increasing --num_bits.")
    else:
        print(f"  Saturation         : None — all values fit without clipping.")
    print("=" * 58)
    print()

    return {'max_abs_err': max_abs_err, 'rms_err': rms_err,
            'snr_db': snr_db, 'clipped': clipped}


# =============================================================================
# SystemVerilog ROM Generator
# =============================================================================

def to_sv_hex(val, num_bits):
    """
    Return a SystemVerilog signed literal for a two's complement value.
    Example: -1 with 16 bits  ->  "16'shFFFF"
    """
    unsigned = val if val >= 0 else val + (1 << num_bits)
    hex_digits = (num_bits + 3) // 4
    return f"{num_bits}'sh{unsigned:0{hex_digits}X}"


def write_sv_rom(coeffs_float, quantized, num_bits, scale, frac_bits, int_bits,
                 module_name, filepath):
    """
    Generate a self-contained parameterized SystemVerilog ROM.

    Coefficients are embedded directly in an initial block — no external
    .mem file is required.

    Synthesis notes:
      - The registered (always_ff) read style infers true Block RAM on both
        Xilinx (Vivado) and Intel (Quartus Prime) FPGAs.
      - The initial block with individual assignments is the standard way to
        initialize BRAM contents without an external file.
      - NUM_TAPS, COEFF_WIDTH, and ADDR_WIDTH are kept as parameters so the
        module can be overridden at instantiation if needed.
    """
    num_taps   = len(quantized)
    addr_width = max(1, math.ceil(math.log2(num_taps)))  # 100 taps -> 7 bits

    os.makedirs(os.path.dirname(os.path.abspath(filepath)), exist_ok=True)

    L = []   # line accumulator

    sep = "/" * 79

    L += [
        f"// {sep}",
        f"// Module      : {module_name}",
        f"// Description : Parameterized synchronous single-port ROM for FIR filter",
        f"//               coefficients.  Coefficient values are embedded directly",
        f"//               in the initial block — no external file needed.",
        f"//",
        f"//               Quantization  : Q{int_bits}.{frac_bits} signed two's complement",
        f"//               Scale factor  : 2^{frac_bits} = {int(scale)}",
        f"//               LSB           : {1.0/scale:.6e}",
        f"//               Num taps      : {num_taps}",
        f"//               Bit-width     : {num_bits}",
        f"//",
        f"// Synthesis    : Registered read (always_ff) -> infers BRAM on Xilinx/Intel.",
        f"//               1-cycle read latency: coeff_out is valid one cycle after addr.",
        f"//",
        f"// Parameters   :",
        f"//   NUM_TAPS    Number of filter taps              (default: {num_taps})",
        f"//   COEFF_WIDTH Bit-width of each coefficient       (default: {num_bits})",
        f"//   ADDR_WIDTH  Address bits = ceil(log2(NUM_TAPS)) (default: {addr_width})",
        f"//",
        f"// Ports        :",
        f"//   clk         Clock",
        f"//   addr        Coefficient index  [ADDR_WIDTH-1:0]   (unsigned)",
        f"//   coeff_out   Coefficient value  [COEFF_WIDTH-1:0]  (signed, Q{int_bits}.{frac_bits})",
        f"// {sep}",
        f"",
        f"module {module_name} #(",
        f"    parameter integer NUM_TAPS    = {num_taps},",
        f"    parameter integer COEFF_WIDTH = {num_bits},",
        f"    parameter integer ADDR_WIDTH  = {addr_width}",
        f")(",
        f"    input  logic                              clk,",
        f"    input  logic [ADDR_WIDTH-1:0]             addr,",
        f"    output logic signed [COEFF_WIDTH-1:0]     coeff_out",
        f");",
        f"",
        f"    // ---------------------------------------------------------------",
        f"    // ROM array - {num_taps} entries, {num_bits} bits each (signed)",
        f"    // ---------------------------------------------------------------",
        f"    logic signed [COEFF_WIDTH-1:0] mem [0:NUM_TAPS-1];",
        f"",
        f"    // ---------------------------------------------------------------",
        f"    // Coefficient initialisation",
        f"    // Values are in Q{int_bits}.{frac_bits} format, scale = 2^{frac_bits} = {int(scale)}",
        f"    // ---------------------------------------------------------------",
        f"    initial begin",
    ]

    # Embed each coefficient as an individual assignment with annotation
    for i, (q, orig) in enumerate(zip(quantized, coeffs_float)):
        sv_lit = to_sv_hex(q, num_bits)
        L.append(f"        mem[{i:3d}] = {sv_lit};  // h[{i:3d}] = {q:7d}  ({orig:+.8f})")

    L += [
        f"    end",
        f"",
        f"    // ---------------------------------------------------------------",
        f"    // Synchronous (registered) read — 1-cycle latency",
        f"    // Registered output is required to infer true BRAM on FPGA.",
        f"    // ---------------------------------------------------------------",
        f"    always_ff @(posedge clk) begin",
        f"        coeff_out <= mem[addr];",
        f"    end",
        f"",
        f"endmodule",
        f"// {sep}",
        f"",
    ]

    with open(filepath, 'w') as f:
        f.write('\n'.join(L))


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description=(
            "Quantize FIR filter coefficients from CSV to fixed-point and "
            "generate a self-contained parameterized SystemVerilog ROM (.sv) "
            "with coefficients embedded directly — no .mem file required."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python quantize_coeffs.py --input coefficients.csv --num_bits 16 --num_taps 100
  python quantize_coeffs.py --input coeffs.csv --num_bits 18 --rom_out ../rtl/coeff_rom.sv
        """
    )
    parser.add_argument("--input",       required=True,
                        help="Input CSV file (one value per row, or comma-separated)")
    parser.add_argument("--num_bits",    type=int, default=16,
                        help="Coefficient bit-width, signed two's complement (default: 16)")
    parser.add_argument("--num_taps",    type=int, default=None,
                        help="Expected number of taps — used for validation only (optional)")
    parser.add_argument("--rom_out",     default="../rtl/coeff_rom.sv",
                        help="Output SystemVerilog ROM path (default: ../rtl/coeff_rom.sv)")
    parser.add_argument("--module_name", default="coeff_rom",
                        help="SystemVerilog module name (default: coeff_rom)")
    parser.add_argument("--skip_header", action="store_true",
                        help="Skip the first CSV row (treat it as a header)")

    args = parser.parse_args()

    if args.num_bits < 2:
        print("ERROR: --num_bits must be >= 2 (1 sign bit + at least 1 data bit).")
        sys.exit(1)

    # --- Read ---
    print(f"Reading coefficients from : {args.input}")
    coeffs = read_csv(args.input, skip_header=args.skip_header)
    if not coeffs:
        print("ERROR: No numeric values found in the input CSV.")
        sys.exit(1)
    print(f"Coefficients read         : {len(coeffs)}")

    # --- Validate tap count ---
    if args.num_taps is not None:
        if len(coeffs) != args.num_taps:
            print(f"ERROR: Expected {args.num_taps} taps but CSV has {len(coeffs)}.")
            sys.exit(1)
        print(f"Tap count validation      : PASSED ({args.num_taps} taps)")

    # --- Quantize ---
    quantized, scale, frac_bits, int_bits, errors = quantize_coefficients(coeffs, args.num_bits)

    # --- Stats ---
    compute_stats(coeffs, quantized, errors, scale, frac_bits, int_bits, args.num_bits)

    # --- Write ROM ---
    write_sv_rom(coeffs, quantized, args.num_bits, scale, frac_bits, int_bits,
                 args.module_name, args.rom_out)
    print(f"Written SystemVerilog ROM : {os.path.abspath(args.rom_out)}")
    print()


if __name__ == "__main__":
    main()
