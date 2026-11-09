# Author: Lorenzo Ambrogiani - ambrogiani.lorenzo2@studio.unibo.it
# Description: Netlist extraction procedures for Fault Injection on the
#              CV32E40PX Register File (SECDED ECC & Scrubbing) in core-v-verif.

# Source generic netlist extraction procs from InjectaFault
source $script_base_path/extract_nets.tcl

# ==============================================================================
#  Hierarchy Paths (core-v-verif UVM Testbench)
# ==============================================================================

# Base path of the CV32E40PX Core
proc core_path {} {
  return "/uvmt_cv32e40px_tb/dut_wrap/cv32e40px_tb_wrapper_i/cv32e40px_top_i/core_i"
}

# Base path of the Register File under test
proc base_path {} {
  return "[core_path]/id_stage_i/register_file_i"
}

# ==============================================================================
#  Ignored Nets (for recursive combinatorial extraction)
# ==============================================================================
set core_netlist_ignore [list]
lappend core_netlist_ignore *clk_i
lappend core_netlist_ignore *Clk_CI
lappend core_netlist_ignore *clk
lappend core_netlist_ignore *clk_ungated_i
lappend core_netlist_ignore *rst_ni
lappend core_netlist_ignore *rst_i
lappend core_netlist_ignore *rst_n
lappend core_netlist_ignore *rst
lappend core_netlist_ignore *Rst_RBI
lappend core_netlist_ignore *scan_cg_en_i
lappend core_netlist_ignore *testmode_i
lappend core_netlist_ignore *tracer_i*

# ==============================================================================
#  Helper Procedures for Bit & Parameter Handling
# ==============================================================================

# Read an integer parameter from the simulation hierarchy (with fallback default)
proc get_sim_param {param_path {default_val 0}} {
  if {[catch {set val [examine -radix dec $param_path]}]} {
    return $default_val
  }
  if {$val eq "" || $val eq "<N/A>"} {
    return $default_val
  }
  return $val
}

# Append a specific bit index [bit_index] if requested (bit_index >= 0).
# If bit_index is -1 or "random", returns the full vector so InjectaFault
# selects a random bit according to the seed.
proc format_target_net {sig_path {bit_index -1}} {
  if {$bit_index eq "" || $bit_index eq "random" || $bit_index < 0} {
    return $sig_path
  }
  set width [get_net_reg_width $sig_path]
  if {$width <= 1} {
    if {$bit_index > 0 && $::verbosity >= 1} {
      echo "\[Netlist Extraction Warning\] Signal $sig_path is 1-bit wide; ignoring bit_index=$bit_index."
    }
    return $sig_path
  }
  if {$bit_index >= $width} {
    if {$::verbosity >= 1} {
      echo "\[Netlist Extraction Error\] Requested bit_index=$bit_index out of range for $sig_path (width=$width). Skipping."
    }
    return ""
  }
  return "${sig_path}\[$bit_index\]"
}

# ==============================================================================
#  Register File Target Extraction Procedures
# ==============================================================================

# 1. Integer Register File (mem[1..31], 39-bit each with SECDED ECC)
#    - reg_indices: single index (e.g. 5), list of indices (e.g. {1 5 10}), or "all" (1..31)
#    - bit_index:   -1 (random bit in [38:0]) or specific bit index 0..38
proc get_rf_mem_nets {{reg_indices "all"} {bit_index -1}} {
  set rf [base_path]
  set netlist [list]

  if {$reg_indices eq "all"} {
    set indices [list]
    # R0 (mem[0]) is hardwired to 0; iterate from R1 to R31
    for {set i 1} {$i < 32} {incr i} {
      lappend indices $i
    }
  } else {
    set indices $reg_indices
  }

  foreach idx $indices {
    set sig "${rf}/mem\[$idx\]"
    set formatted [format_target_net $sig $bit_index]
    if {$formatted ne ""} {
      lappend netlist $formatted
    }
  }
  return $netlist
}

# 2. Floating-Point Register File (mem_fp[0..31], 39-bit each, active when FPU=1 and ZFINX=0)
#    - reg_indices: single index (e.g. 0), list of indices (e.g. {0 1 2}), or "all" (0..31)
#    - bit_index:   -1 (random bit in [38:0]) or specific bit index 0..38
proc get_rf_mem_fp_nets {{reg_indices "all"} {bit_index -1}} {
  set rf [base_path]
  set fpu   [get_sim_param "${rf}/FPU" 0]
  set zfinx [get_sim_param "${rf}/ZFINX" 0]

  if {$fpu != 1 || $zfinx != 0} {
    if {$::verbosity >= 1} {
      echo "\[Netlist Extraction Warning\] FP Register File (mem_fp) is tied to 0 in current configuration (FPU=$fpu, ZFINX=$zfinx). Skipping mem_fp."
    }
    return [list]
  }

  set netlist [list]
  if {$reg_indices eq "all"} {
    set indices [list]
    for {set l 0} {$l < 32} {incr l} {
      lappend indices $l
    }
  } else {
    set indices $reg_indices
  }

  foreach idx $indices {
    set sig "${rf}/mem_fp\[$idx\]"
    set formatted [format_target_net $sig $bit_index]
    if {$formatted ne ""} {
      lappend netlist $formatted
    }
  }
  return $netlist
}

# 3. Scrubbing Buffers (u_scrub_buf_a, u_scrub_buf_b, u_scrub_buf_c)
#    - ports:     "a", "b", "c", a list like {a b}, or "all"
#    - fields:    "data_q" (39-bit), "addr_q" (6-bit), "valid_q" (1-bit), or "all"
#    - bit_index: -1 (random bit) or specific bit index
#    - channels:  0, 1 (if X_DUALREAD=1), or "all"
proc get_rf_scrub_buf_nets {{ports "all"} {fields "all"} {bit_index -1} {channels "all"}} {
  set rf [base_path]
  set x_dualread [get_sim_param "${rf}/X_DUALREAD" 0]

  if {$channels eq "all"} {
    set ch_list [list]
    for {set ch 0} {$ch <= $x_dualread} {incr ch} {
      lappend ch_list $ch
    }
  } else {
    set ch_list $channels
  }

  if {$ports eq "all"} {
    set port_list [list "a" "b" "c"]
  } else {
    set port_list $ports
  }

  if {$fields eq "all"} {
    set field_list [list "data_q" "addr_q" "valid_q"]
  } else {
    set field_list $fields
  }

  set netlist [list]
  foreach ch $ch_list {
    foreach p $port_list {
      foreach f $field_list {
        set sig "${rf}/gen_ecc_read_channels\[$ch\]/u_scrub_buf_${p}/${f}"
        set formatted [format_target_net $sig $bit_index]
        if {$formatted ne ""} {
          lappend netlist $formatted
        }
      }
    }
  }
  return $netlist
}

# 4. Unified Target Selector called by inject_fault.tcl
#    - group: "mem", "mem_fp", "scrub_buf", or "all"
proc get_rf_target_nets {group reg_indices bit_index {scrub_ports "all"} {scrub_fields "all"} {scrub_channels "all"}} {
  set netlist [list]

  if {$group eq "mem" || $group eq "all"} {
    set netlist [concat $netlist [get_rf_mem_nets $reg_indices $bit_index]]
  }
  if {$group eq "mem_fp" || $group eq "all"} {
    set netlist [concat $netlist [get_rf_mem_fp_nets $reg_indices $bit_index]]
  }
  if {$group eq "scrub_buf" || $group eq "all"} {
    set netlist [concat $netlist [get_rf_scrub_buf_nets $scrub_ports $scrub_fields $bit_index $scrub_channels]]
  }

  return $netlist
}

# ==============================================================================
#  Register File Output Nets (for check_core_output_modification)
# ==============================================================================
# Extracts all outputs of cv32e40px_register_file:
#   - rdata_a_o, rdata_b_o, rdata_c_o
#   - err_single_a_o, err_mult_a_o, err_single_b_o, err_mult_b_o, err_single_c_o, err_mult_c_o
proc get_core_output_nets {} {
  set rf_outputs [get_output_netlist [base_path]]
  return [extract_netlists $rf_outputs 0]
}

# ==============================================================================
#  Combinatorial Nets inside Register File (optional SET testing)
# ==============================================================================
proc get_all_core_nets {} {
  return [extract_all_nets_recursive_filtered [base_path] $::core_netlist_ignore]
}
