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
// Design Name:    Single-Entry Scrubbing Buffer with Write Snooping          //
// Project Name:   RI5CY / CV32E40PX                                          //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Captures single-bit corrected ECC words from a register    //
//                 file read port and holds them until the scrubbing arbiter  //
//                 writes them back or a normal write overwrites the same     //
//                 register address (write snooping).                         //
////////////////////////////////////////////////////////////////////////////////

module cv32e40px_scrub_buffer #(
    parameter int unsigned ADDR_WIDTH = 5,
    parameter int unsigned ECC_WIDTH  = 39
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
  assign is_r0 = (err_addr_i == '0);

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
