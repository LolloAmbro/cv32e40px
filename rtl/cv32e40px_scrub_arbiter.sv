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
// Design Name:    Parametric Scrubbing Arbiter                               //
// Project Name:   RI5CY / CV32E40PX                                          //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Fixed-priority arbiter for scrubbing buffers (index 0 has  //
//                 highest priority). Grants buffer pop when the target write //
//                 port is idle and suppresses write enable on same-cycle     //
//                 address collision with the other write port.               //
////////////////////////////////////////////////////////////////////////////////

module cv32e40px_scrub_arbiter #(
    parameter int unsigned NUM_REQS   = 1,
    parameter int unsigned ADDR_WIDTH = 5,
    parameter int unsigned ECC_WIDTH  = 39
) (
    // Scrubbing buffers interface
    input  logic [NUM_REQS-1:0]                 req_valid_i,
    input  logic [NUM_REQS-1:0][ADDR_WIDTH-1:0] req_addr_i,
    input  logic [NUM_REQS-1:0][ECC_WIDTH-1:0]  req_data_i,
    output logic [NUM_REQS-1:0]                 req_pop_o,

    // Target write port status (own port)
    input  logic                                we_own_i,

    // Other write port status (for same-cycle collision check)
    input  logic                                we_other_i,
    input  logic [ADDR_WIDTH-1:0]               waddr_other_i,

    // Arbitrated scrubbing write output (towards Write MUX)
    output logic                                scrub_we_o,
    output logic [ADDR_WIDTH-1:0]               scrub_addr_o,
    output logic [ECC_WIDTH-1:0]                scrub_data_o
);

  logic arb_req;
  logic arb_collision;

  always_comb begin
    arb_req      = 1'b0;
    scrub_addr_o = '0;
    scrub_data_o = '0;
    req_pop_o    = '0;

    // Fixed priority selection (lower index has higher priority: 0 > 1 > ...)
    for (int idx = 0; idx < NUM_REQS; idx++) begin
      if (!arb_req && req_valid_i[idx]) begin
        arb_req      = 1'b1;
        scrub_addr_o = req_addr_i[idx];
        scrub_data_o = req_data_i[idx];
        // Pop the buffer only when the target write port is free
        if (!we_own_i) begin
          req_pop_o[idx] = 1'b1;
        end
      end
    end
  end

  // Same-cycle collision check with the other write port
  assign arb_collision = (we_other_i && (waddr_other_i == scrub_addr_o));

  // Execute scrubbing write only if own port is free and other port is not writing the same register
  assign scrub_we_o    = arb_req && !we_own_i && !arb_collision;

endmodule
