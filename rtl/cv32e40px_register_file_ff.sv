// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Francesco Conti - f.conti@unibo.it                         //
//                                                                            //
// Additional contributions by:                                               //
//                 Michael Gautschi - gautschi@iis.ee.ethz.ch                 //
//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                 ECC & Scrubbing Integration                                //
//                                                                            //
// Design Name:    RISC-V register file with SECDED ECC and Scrubbing         //
// Project Name:   RI5CY / CV32E40PX                                          //
// Language:       SystemVerilog                                              //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

//------------------------------------------------------------------------------
// Helper Module: Single-Entry Scrubbing Buffer with Write Snooping
//------------------------------------------------------------------------------
module cv32e40px_scrub_buffer #(
    parameter int unsigned ADDR_WIDTH = 5,
    parameter int unsigned ECC_WIDTH  = 39,
    parameter int unsigned FPU        = 0,
    parameter int unsigned ZFINX      = 0
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // Capture interface from Corrector
    input  logic                  err_detect_i,
    input  logic [ADDR_WIDTH-1:0] err_addr_i,
    input  logic [ECC_WIDTH-1:0]  err_data_i,

    // Snooping interface (Normal Write Ports W1 & W2)
    input  logic                  snoop_we_a_i,
    input  logic [ADDR_WIDTH-1:0] snoop_waddr_a_i,
    input  logic                  snoop_we_b_i,
    input  logic [ADDR_WIDTH-1:0] snoop_waddr_b_i,

    // Arbiter handshake interface
    input  logic                  pop_i,
    output logic                  valid_o,
    output logic [ADDR_WIDTH-1:0] addr_o,
    output logic [ECC_WIDTH-1:0]  data_o
);

  logic                  valid_q;
  logic [ADDR_WIDTH-1:0] addr_q;
  logic [ECC_WIDTH-1:0]  data_q;

  logic is_r0;
  logic snoop_hit_on_capture;
  logic snoop_hit_on_stored;
  logic capture_en;

  // Check if the address refers to integer register R0 (hardwired to 0)
  generate
    if (FPU == 1 && ZFINX == 0 && ADDR_WIDTH > 5) begin : gen_r0_check_fp
      assign is_r0 = (err_addr_i[5:0] == 6'b000000);
    end else begin : gen_r0_check_int
      assign is_r0 = (err_addr_i[4:0] == 5'b00000);
    end
  endgenerate

  // Collision check during error detection cycle (Cycle T)
  assign snoop_hit_on_capture = (snoop_we_a_i && (snoop_waddr_a_i == err_addr_i)) ||
                                (snoop_we_b_i && (snoop_waddr_b_i == err_addr_i));

  // Collision check while waiting in the buffer (Cycles T+1 .. T+N)
  assign snoop_hit_on_stored  = (snoop_we_a_i && (snoop_waddr_a_i == addr_q)) ||
                                (snoop_we_b_i && (snoop_waddr_b_i == addr_q));

  // Valid error capture condition (ignore R0 and immediate WAR collisions)
  assign capture_en = err_detect_i && !is_r0 && !snoop_hit_on_capture;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      addr_q  <= '0;
      data_q  <= '0;
    end else begin
      if (capture_en) begin
        // Load new corrected word (or overwrite existing/popped entry)
        valid_q <= 1'b1;
        addr_q  <= err_addr_i;
        data_q  <= err_data_i;
      end else if (pop_i || snoop_hit_on_stored) begin
        // Invalidate if consumed by arbiter OR overwritten by normal RF write
        valid_q <= 1'b0;
      end
    end
  end

  assign valid_o = valid_q;
  assign addr_o  = addr_q;
  assign data_o  = data_q;

endmodule


//------------------------------------------------------------------------------
// Main Module: Register File with ECC & Scrubbing
//------------------------------------------------------------------------------
module cv32e40px_register_file #(
    parameter ADDR_WIDTH = 5,
    parameter DATA_WIDTH = 32,
    parameter FPU        = 0,
    parameter ZFINX      = 0,
    parameter COREV_X_IF = 0,
    parameter X_DUALREAD = 0
) (
    // Clock and Reset
    input  logic clk,
    input  logic rst_n,

    input  logic scan_cg_en_i,

    input  logic [2:0] dualread_i,

    // Read port R1
    input  logic [ADDR_WIDTH-1:0]               raddr_a_i,
    output logic [X_DUALREAD:0][DATA_WIDTH-1:0] rdata_a_o,

    // Read port R2
    input  logic [ADDR_WIDTH-1:0]               raddr_b_i,
    output logic [X_DUALREAD:0][DATA_WIDTH-1:0] rdata_b_o,

    // Read port R3
    input  logic [ADDR_WIDTH-1:0]               raddr_c_i,
    output logic [X_DUALREAD:0][DATA_WIDTH-1:0] rdata_c_o,

    // Write port W1
    input  logic [ADDR_WIDTH-1:0]               waddr_a_i,
    input  logic [DATA_WIDTH-1:0]               wdata_a_i,
    input  logic                                we_a_i,

    // Write port W2
    input  logic [ADDR_WIDTH-1:0]               waddr_b_i,
    input  logic [DATA_WIDTH-1:0]               wdata_b_i,
    input  logic                                we_b_i,

    // ECC Error Reporting Outputs (towards Control Unit)
    output logic [X_DUALREAD:0]                 err_single_a_o,
    output logic [X_DUALREAD:0]                 err_mult_a_o,
    output logic [X_DUALREAD:0]                 err_single_b_o,
    output logic [X_DUALREAD:0]                 err_mult_b_o,
    output logic [X_DUALREAD:0]                 err_single_c_o,
    output logic [X_DUALREAD:0]                 err_mult_c_o
);

  // ECC local parameters (SECDED 39,32)
  localparam int unsigned ECC_WIDTH = DATA_WIDTH + 7;

  // number of integer registers
  localparam NUM_WORDS     = 2 ** (ADDR_WIDTH - 1);
  // number of floating point registers
  localparam NUM_FP_WORDS  = 2 ** (ADDR_WIDTH - 1);
  localparam NUM_TOT_WORDS = FPU ? (ZFINX ? NUM_WORDS : NUM_WORDS + NUM_FP_WORDS) : NUM_WORDS;

  // integer register file (39-bit wide for ECC)
  logic [   NUM_WORDS-1:0][ECC_WIDTH-1:0] mem;

  // fp register file (39-bit wide for ECC)
  logic [NUM_FP_WORDS-1:0][ECC_WIDTH-1:0] mem_fp;

  // Effective write signals after Write / Scrubbing MUXes
  logic [  ADDR_WIDTH-1:0]                waddr_a;
  logic [  ADDR_WIDTH-1:0]                waddr_b;
  logic [   ECC_WIDTH-1:0]                wdata_a_mux;
  logic [   ECC_WIDTH-1:0]                wdata_b_mux;
  logic                                   we_a_mux;
  logic                                   we_b_mux;

  // Encoded incoming write data
  logic [   ECC_WIDTH-1:0]                wdata_a_enc;
  logic [   ECC_WIDTH-1:0]                wdata_b_enc;

  // write enable signals for all registers
  logic [NUM_TOT_WORDS-1:0]               we_a_dec;
  logic [NUM_TOT_WORDS-1:0]               we_b_dec;

  //-----------------------------------------------------------------------------
  //-- READ : Raw Encoded Data Extraction & Corrector Instantiation
  //-----------------------------------------------------------------------------
  logic [X_DUALREAD:0][ECC_WIDTH-1:0]  rdata_a_raw, rdata_b_raw, rdata_c_raw;
  logic [X_DUALREAD:0][ECC_WIDTH-1:0]  rdata_a_cor, rdata_b_cor, rdata_c_cor;
  logic [X_DUALREAD:0][ADDR_WIDTH-1:0] raddr_a_eff, raddr_b_eff, raddr_c_eff;
  logic [X_DUALREAD:0]                 rport_a_en,  rport_b_en,  rport_c_en;
  logic [X_DUALREAD:0][1:0]            err_a_raw,   err_b_raw,   err_c_raw;

  generate
    if (COREV_X_IF != 0 && X_DUALREAD != 0) begin : gen_corev_x_if_dualread
      // Effective addresses for channel 0
      assign raddr_a_eff[0] = raddr_a_i;
      assign raddr_b_eff[0] = raddr_b_i;
      assign raddr_c_eff[0] = raddr_c_i;

      // Effective addresses for channel 1 (dualread)
      assign raddr_a_eff[1] = {raddr_a_i[ADDR_WIDTH-1:1], raddr_a_i[0] | 1'b1};
      assign raddr_b_eff[1] = {raddr_b_i[ADDR_WIDTH-1:1], raddr_b_i[0] | 1'b1};
      assign raddr_c_eff[1] = {raddr_c_i[ADDR_WIDTH-1:1], raddr_c_i[0] | 1'b1};

      // Port enables (avoid duplicate scrubbing if raddr[0] == 1'b1)
      assign rport_a_en[0]  = 1'b1;
      assign rport_b_en[0]  = 1'b1;
      assign rport_c_en[0]  = 1'b1;
      assign rport_a_en[1]  = (dualread_i[0] == 1'b1) && (raddr_a_i[0] == 1'b0);
      assign rport_b_en[1]  = (dualread_i[1] == 1'b1) && (raddr_b_i[0] == 1'b0);
      assign rport_c_en[1]  = (dualread_i[2] == 1'b1) && (raddr_c_i[0] == 1'b0);

      always_comb begin
        // Channel 0 raw read
        rdata_a_raw[0] = raddr_a_i[5] ? mem_fp[raddr_a_i[4:0]] : mem[raddr_a_i[4:0]];
        rdata_b_raw[0] = raddr_b_i[5] ? mem_fp[raddr_b_i[4:0]] : mem[raddr_b_i[4:0]];
        rdata_c_raw[0] = raddr_c_i[5] ? mem_fp[raddr_c_i[4:0]] : mem[raddr_c_i[4:0]];

        // Channel 1 raw read
        if (dualread_i[0] == 1'b1)
          rdata_a_raw[1] = raddr_a_i[5] ? mem_fp[{raddr_a_i[4:1], raddr_a_i[0]|1'b1}]
                                        : mem[{raddr_a_i[4:1], raddr_a_i[0]|1'b1}];
        else
          rdata_a_raw[1] = '0;

        if (dualread_i[1] == 1'b1)
          rdata_b_raw[1] = raddr_b_i[5] ? mem_fp[{raddr_b_i[4:1], raddr_b_i[0]|1'b1}]
                                        : mem[{raddr_b_i[4:1], raddr_b_i[0]|1'b1}];
        else
          rdata_b_raw[1] = '0;

        if (dualread_i[2] == 1'b1)
          rdata_c_raw[1] = raddr_c_i[5] ? mem_fp[{raddr_c_i[4:1], raddr_c_i[0]|1'b1}]
                                        : mem[{raddr_c_i[4:1], raddr_c_i[0]|1'b1}];
        else
          rdata_c_raw[1] = '0;
      end
    end else begin : gen_single_read
      assign raddr_a_eff[0] = raddr_a_i;
      assign raddr_b_eff[0] = raddr_b_i;
      assign raddr_c_eff[0] = raddr_c_i;

      assign rport_a_en[0]  = 1'b1;
      assign rport_b_en[0]  = 1'b1;
      assign rport_c_en[0]  = 1'b1;

      assign rdata_a_raw[0] = raddr_a_i[5] ? mem_fp[raddr_a_i[4:0]] : mem[raddr_a_i[4:0]];
      assign rdata_b_raw[0] = raddr_b_i[5] ? mem_fp[raddr_b_i[4:0]] : mem[raddr_b_i[4:0]];
      assign rdata_c_raw[0] = raddr_c_i[5] ? mem_fp[raddr_c_i[4:0]] : mem[raddr_c_i[4:0]];
    end
  endgenerate

  //-----------------------------------------------------------------------------
  //-- CORRECTORS & SCRUBBING BUFFERS
  //-----------------------------------------------------------------------------
  logic [X_DUALREAD:0]                 sb_a_valid, sb_b_valid, sb_c_valid;
  logic [X_DUALREAD:0]                 sb_a_pop,   sb_b_pop,   sb_c_pop;
  logic [X_DUALREAD:0][ADDR_WIDTH-1:0] sb_a_addr,  sb_b_addr,  sb_c_addr;
  logic [X_DUALREAD:0][ECC_WIDTH-1:0]  sb_a_data,  sb_b_data,  sb_c_data;

  genvar ch;
  generate
    for (ch = 0; ch <= X_DUALREAD; ch++) begin : gen_ecc_read_channels

      // --- PORT A Corrector & Scrub Buffer ---
      prim_secded_39_32_cor u_cor_a (
          .d_i        ( rdata_a_raw[ch] ),
          .d_o        ( rdata_a_cor[ch] ),
          .syndrome_o (                 ),
          .err_o      ( err_a_raw[ch]   )
      );

      assign rdata_a_o[ch]      = (ch == 1 && !dualread_i[0]) ? '0 : rdata_a_cor[ch][DATA_WIDTH-1:0];
      assign err_single_a_o[ch] = rport_a_en[ch] ? err_a_raw[ch][0] : 1'b0;
      assign err_mult_a_o[ch]   = rport_a_en[ch] ? err_a_raw[ch][1] : 1'b0;

      cv32e40px_scrub_buffer #(
          .ADDR_WIDTH ( ADDR_WIDTH ),
          .ECC_WIDTH  ( ECC_WIDTH  ),
          .FPU        ( FPU        ),
          .ZFINX      ( ZFINX      )
      ) u_scrub_buf_a (
          .clk             ( clk                ),
          .rst_n           ( rst_n              ),
          .err_detect_i    ( err_single_a_o[ch] ), // Scrub only single-bit correctable errors
          .err_addr_i      ( raddr_a_eff[ch]    ),
          .err_data_i      ( rdata_a_cor[ch]    ),
          .snoop_we_a_i    ( we_a_i             ),
          .snoop_waddr_a_i ( waddr_a_i          ),
          .snoop_we_b_i    ( we_b_i             ),
          .snoop_waddr_b_i ( waddr_b_i          ),
          .pop_i           ( sb_a_pop[ch]       ),
          .valid_o         ( sb_a_valid[ch]     ),
          .addr_o          ( sb_a_addr[ch]      ),
          .data_o          ( sb_a_data[ch]      )
      );

      // --- PORT B Corrector & Scrub Buffer ---
      prim_secded_39_32_cor u_cor_b (
          .d_i        ( rdata_b_raw[ch] ),
          .d_o        ( rdata_b_cor[ch] ),
          .syndrome_o (                 ),
          .err_o      ( err_b_raw[ch]   )
      );

      assign rdata_b_o[ch]      = (ch == 1 && !dualread_i[1]) ? '0 : rdata_b_cor[ch][DATA_WIDTH-1:0];
      assign err_single_b_o[ch] = rport_b_en[ch] ? err_b_raw[ch][0] : 1'b0;
      assign err_mult_b_o[ch]   = rport_b_en[ch] ? err_b_raw[ch][1] : 1'b0;

      cv32e40px_scrub_buffer #(
          .ADDR_WIDTH ( ADDR_WIDTH ),
          .ECC_WIDTH  ( ECC_WIDTH  ),
          .FPU        ( FPU        ),
          .ZFINX      ( ZFINX      )
      ) u_scrub_buf_b (
          .clk             ( clk                ),
          .rst_n           ( rst_n              ),
          .err_detect_i    ( err_single_b_o[ch] ),
          .err_addr_i      ( raddr_b_eff[ch]    ),
          .err_data_i      ( rdata_b_cor[ch]    ),
          .snoop_we_a_i    ( we_a_i             ),
          .snoop_waddr_a_i ( waddr_a_i          ),
          .snoop_we_b_i    ( we_b_i             ),
          .snoop_waddr_b_i ( waddr_b_i          ),
          .pop_i           ( sb_b_pop[ch]       ),
          .valid_o         ( sb_b_valid[ch]     ),
          .addr_o          ( sb_b_addr[ch]      ),
          .data_o          ( sb_b_data[ch]      )
      );

      // --- PORT C Corrector & Scrub Buffer ---
      prim_secded_39_32_cor u_cor_c (
          .d_i        ( rdata_c_raw[ch] ),
          .d_o        ( rdata_c_cor[ch] ),
          .syndrome_o (                 ),
          .err_o      ( err_c_raw[ch]   )
      );

      assign rdata_c_o[ch]      = (ch == 1 && !dualread_i[2]) ? '0 : rdata_c_cor[ch][DATA_WIDTH-1:0];
      assign err_single_c_o[ch] = rport_c_en[ch] ? err_c_raw[ch][0] : 1'b0;
      assign err_mult_c_o[ch]   = rport_c_en[ch] ? err_c_raw[ch][1] : 1'b0;

      cv32e40px_scrub_buffer #(
          .ADDR_WIDTH ( ADDR_WIDTH ),
          .ECC_WIDTH  ( ECC_WIDTH  ),
          .FPU        ( FPU        ),
          .ZFINX      ( ZFINX      )
      ) u_scrub_buf_c (
          .clk             ( clk                ),
          .rst_n           ( rst_n              ),
          .err_detect_i    ( err_single_c_o[ch] ),
          .err_addr_i      ( raddr_c_eff[ch]    ),
          .err_data_i      ( rdata_c_cor[ch]    ),
          .snoop_we_a_i    ( we_a_i             ),
          .snoop_waddr_a_i ( waddr_a_i          ),
          .snoop_we_b_i    ( we_b_i             ),
          .snoop_waddr_b_i ( waddr_b_i          ),
          .pop_i           ( sb_c_pop[ch]       ),
          .valid_o         ( sb_c_valid[ch]     ),
          .addr_o          ( sb_c_addr[ch]      ),
          .data_o          ( sb_c_data[ch]      )
      );

    end
  endgenerate

  //-----------------------------------------------------------------------------
  //-- SCRUB ARBITER 1 (Upper Branch -> Write Port A)
  //-----------------------------------------------------------------------------
  logic                  arb_a_req;
  logic [ADDR_WIDTH-1:0] arb_a_addr;
  logic [ECC_WIDTH-1:0]  arb_a_data;
  logic                  arb_a_collision;
  logic                  scrub_we_a;

  always_comb begin
    arb_a_req  = 1'b0;
    arb_a_addr = '0;
    arb_a_data = '0;
    sb_a_pop   = '0;

    // Fixed priority selection among Port A channels (ch 0 > ch 1)
    for (int idx = 0; idx <= X_DUALREAD; idx++) begin
      if (!arb_a_req && sb_a_valid[idx]) begin
        arb_a_req  = 1'b1;
        arb_a_addr = sb_a_addr[idx];
        arb_a_data = sb_a_data[idx];
        // Pop the buffer only when Write Port A is free (no normal write on W1)
        if (!we_a_i) begin
          sb_a_pop[idx] = 1'b1;
        end
      end
    end
  end

  // Same-cycle collision check with Write Port B (if W2 is writing the same address right now)
  assign arb_a_collision = (we_b_i && (waddr_b_i == arb_a_addr));
  // Execute scrubbing write on Port A only if W1 is free and W2 is not overwriting the same reg
  assign scrub_we_a      = arb_a_req && !we_a_i && !arb_a_collision;

  //-----------------------------------------------------------------------------
  //-- SCRUB ARBITER 2 (Lower Branch -> Write Port B)
  //-----------------------------------------------------------------------------
  logic                  arb_bc_req;
  logic [ADDR_WIDTH-1:0] arb_bc_addr;
  logic [ECC_WIDTH-1:0]  arb_bc_data;
  logic                  arb_bc_collision;
  logic                  scrub_we_b;

  always_comb begin
    arb_bc_req  = 1'b0;
    arb_bc_addr = '0;
    arb_bc_data = '0;
    sb_b_pop    = '0;
    sb_c_pop    = '0;

    // Priority: Port B channels first, then Port C channels
    for (int idx = 0; idx <= X_DUALREAD; idx++) begin
      if (!arb_bc_req && sb_b_valid[idx]) begin
        arb_bc_req  = 1'b1;
        arb_bc_addr = sb_b_addr[idx];
        arb_bc_data = sb_b_data[idx];
        if (!we_b_i) begin
          sb_b_pop[idx] = 1'b1;
        end
      end
    end

    for (int idx = 0; idx <= X_DUALREAD; idx++) begin
      if (!arb_bc_req && sb_c_valid[idx]) begin
        arb_bc_req  = 1'b1;
        arb_bc_addr = sb_c_addr[idx];
        arb_bc_data = sb_c_data[idx];
        if (!we_b_i) begin
          sb_c_pop[idx] = 1'b1;
        end
      end
    end
  end

  // Same-cycle collision check with Write Port A (if W1 is writing the same address right now)
  assign arb_bc_collision = (we_a_i && (waddr_a_i == arb_bc_addr));
  // Execute scrubbing write on Port B only if W2 is free and W1 is not overwriting the same reg
  assign scrub_we_b       = arb_bc_req && !we_b_i && !arb_bc_collision;

  //-----------------------------------------------------------------------------
  //-- WRITE : Encoders & Write Multiplexers (Normal Write > Scrubbing Write)
  //-----------------------------------------------------------------------------
  prim_secded_39_32_enc u_enc_a (
      .in  ( wdata_a_i   ),
      .out ( wdata_a_enc )
  );

  prim_secded_39_32_enc u_enc_b (
      .in  ( wdata_b_i   ),
      .out ( wdata_b_enc )
  );

  // Write Port A MUX (Normal W1 has strict priority over Scrub Arbiter 1)
  assign we_a_mux    = we_a_i ? 1'b1        : scrub_we_a;
  assign waddr_a     = we_a_i ? waddr_a_i   : arb_a_addr;
  assign wdata_a_mux = we_a_i ? wdata_a_enc : arb_a_data;

  // Write Port B MUX (Normal W2 has strict priority over Scrub Arbiter 2)
  assign we_b_mux    = we_b_i ? 1'b1        : scrub_we_b;
  assign waddr_b     = we_b_i ? waddr_b_i   : arb_bc_addr;
  assign wdata_b_mux = we_b_i ? wdata_b_enc : arb_bc_data;

  //-----------------------------------------------------------------------------
  //-- WRITE : Write Address Decoder (WAD), combinatorial process
  //-----------------------------------------------------------------------------
  genvar gidx;
  generate
    for (gidx = 0; gidx < NUM_TOT_WORDS; gidx++) begin : gen_we_decoder
      assign we_a_dec[gidx] = (waddr_a == gidx) ? we_a_mux : 1'b0;
      assign we_b_dec[gidx] = (waddr_b == gidx) ? we_b_mux : 1'b0;
    end
  endgenerate

  genvar i, l;
  generate

    //-----------------------------------------------------------------------------
    //-- WRITE : Write operation
    //-----------------------------------------------------------------------------
    // R0 is nil (39'b0 has valid syndrome 7'b0 in prim_secded_39_32)
    always_ff @(posedge clk or negedge rst_n) begin
      if (~rst_n) begin
        mem[0] <= '0;
      end else begin
        mem[0] <= '0;
      end
    end

    // loop from 1 to NUM_WORDS-1 as R0 is nil
    for (i = 1; i < NUM_WORDS; i++) begin : gen_rf

      always_ff @(posedge clk, negedge rst_n) begin : register_write_behavioral
        if (rst_n == 1'b0) begin
          mem[i] <= '0;
        end else begin
          if (we_b_dec[i] == 1'b1)      mem[i] <= wdata_b_mux;
          else if (we_a_dec[i] == 1'b1) mem[i] <= wdata_a_mux;
        end
      end

    end

    if (FPU == 1 && ZFINX == 0) begin : gen_mem_fp_write
      // Floating point registers
      for (l = 0; l < NUM_FP_WORDS; l++) begin
        always_ff @(posedge clk, negedge rst_n) begin : fp_regs
          if (rst_n == 1'b0)                     mem_fp[l] <= '0;
          else if (we_b_dec[l+NUM_WORDS] == 1'b1) mem_fp[l] <= wdata_b_mux;
          else if (we_a_dec[l+NUM_WORDS] == 1'b1) mem_fp[l] <= wdata_a_mux;
        end
      end
    end else begin : gen_no_mem_fp_write
      assign mem_fp = '0;
    end

  endgenerate

endmodule