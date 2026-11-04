# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Description: Fault Injection configuration script for CV32E40PX Register File

# transcript quietly

set current_script_dir [file dirname [file normalize [info script]]]
set script_base_path   $current_script_dir/InjectaFault/scripts

# ==============================================================================
#  1. General & Logging Settings
# ==============================================================================
set verbosity            2      ;# 2 = Print initialization info and every bitflip
set log_injections       1      ;# 1 = Save CSV log (fault_injection_<timestamp>.log)
set seed             12345      ;# Random seed (used when target_reg/bit is random)
set print_statistics     1      ;# 1 = Print summary statistics

# Source CV32E40PX Register File net extraction procedures
source $current_script_dir/extract_nets.tcl

# ==============================================================================
#  2. Target Register & Bit Selection
# ==============================================================================
# Choose which part of the Register File to target:
#   "mem"       : Integer Register File (mem[1..31], 39-bit SECDED word)
#   "mem_fp"    : Floating-Point Register File (mem_fp[0..31], requires FPU=1, ZFINX=0)
#   "scrub_buf" : ECC Scrubbing Buffers (u_scrub_buf_a/b/c)
#   "all"       : All of the above
set target_group          "mem"

# Choose which register(s) to target (used for "mem" and "mem_fp"):
#   - Single index : e.g. 5        (targets only mem[5])
#   - List         : e.g. {1 5 10} (randomly picks among mem[1], mem[5], mem[10])
#   - All          : "all"         (randomly picks among all valid registers)
set target_reg_index      1

# Choose which bit to flip inside the selected register:
#   - Random bit   : -1            (InjectaFault picks a random bit in [38:0] using 'seed')
#   - Specific bit : 0 .. 38       (flips exactly that bit: 0..31 = data, 32..38 = ECC parity)
set target_bit_index      -1

# Extra options when target_group is "scrub_buf" (or "all"):
set target_scrub_ports    "a"      ;# "a", "b", "c", {a b}, or "all"
set target_scrub_fields   "data_q" ;# "data_q" (39b), "addr_q" (6b), "valid_q" (1b), or "all"
set target_scrub_channels "all"    ;# 0, 1 (if X_DUALREAD=1), or "all"

# ==============================================================================
#  3. Timing & Injection Mode (Single Bitflip vs Periodic)
# ==============================================================================
set inject_start_time            10000ns
set inject_stop_time             0
set injection_clock              "[core_path]/clk_i"
set injection_clock_trigger      0   ;# Inject on low clock phase to avoid setup/hold race

# --- MODE A: Single Bitflip (ACTIVE) ---
# Injects 1 bitflip at the first falling clock phase after inject_start_time, then stops.
set fault_period                 1
set max_num_fault_inject         1
set rand_initial_injection_phase 0

# --- MODE B: Periodic Bitflips (DISABLED - uncomment for periodic campaign) ---
# set fault_period                 100 ;# Inject 1 fault every N clock cycles
# set max_num_fault_inject         0   ;# 0 = unlimited (until simulation ends or inject_stop_time)
# set rand_initial_injection_phase 0   ;# 1 = randomize initial cycle offset within fault_period

set signal_fault_duration        20ns
set register_fault_duration      0ns ;# 0ns = release force immediately so FF holds flipped state (SEU)

# ==============================================================================
#  4. Flip & Output Modification Check Settings
# ==============================================================================
set allow_multi_bit_upset              1 ;# 1 = Allow flipping another bit in an already-flipped register
set use_bitwidth_as_weight             1 ;# Weight random selection by register bit-width
set check_core_output_modification     1 ;# 1 = Check & log if RF outputs change upon injection
set check_core_next_state_modification 0 ;# 0 = Disabled (RF has no FSM next-state signals)
set reg_to_sig_ratio                   1

# ==============================================================================
#  5. Populate Netlists & Launch InjectaFault
# ==============================================================================
# Target registers are placed in 'inject_register_netlist' so InjectaFault injects
# persistent SEUs (kept in the flip-flop until overwritten by normal write or scrubbing).
set inject_register_netlist [get_rf_target_nets \
  $target_group \
  $target_reg_index \
  $target_bit_index \
  $target_scrub_ports \
  $target_scrub_fields \
  $target_scrub_channels \
]

set inject_signals_netlist  [list]
set output_netlist          [get_core_output_nets]
set next_state_netlist      [list]
set assertion_disable_list  [list]

# Start the fault injection engine
source $script_base_path/inject_fault.tcl
