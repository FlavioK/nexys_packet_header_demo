//=============================================================================
//               ------->  Revision History  <------
//=============================================================================
//
//   Date     Who   Ver  Changes
//=============================================================================
// 27-Sep-24  FLSO    1  Initial version
//=============================================================================
/*

    This module can be used to generate packets with the requested lengths.
    As soon as a new valid length is provided, the module generates a package
    with random data of and streams it out to the axi stream.
*/
module packet_gen # (parameter DW=128, MAX_LENGTH_WIDTH = 16)
(
    input   clk, resetn,

    // Signal to clear the counter used to fill the packets.
    input feeding_running,

    // Package length to outpu
    input [MAX_LENGTH_WIDTH-1:0] axis_in_length_tdata,
    input                        axis_in_length_tvalid,
    // This is here to satisfy the ILA
    input                        axis_in_length_tlast,
    output                       axis_in_length_tready,

    // Our output stream
    output     [DW-1:0]    axis_out_tdata,
    output reg [DW/8-1:0]  axis_out_tkeep,
    output                 axis_out_tlast,
    output                 axis_out_tvalid,
    input                  axis_out_tready
);

// This is the number of bytes in axis_out_tdata
localparam DB = (DW/8);

// How many bits does it take to represent "DB-1" ?
localparam LOG2_DB = $clog2(DB);

// This is 'LOG2_DB' '1' bits in a row
localparam DB_MASK = (1 << LOG2_DB) - 1;

// Current data-cycle, numbered 1 thru N
reg[MAX_LENGTH_WIDTH:0] cycle;

// The length of the packet currently being output
reg [MAX_LENGTH_WIDTH-1:0] packet_length;

// The number of "packed full" cycles in the packet
reg [MAX_LENGTH_WIDTH:0] whole_data_cycles;

// The number of bytes in the (potentially) partially full last cycle
reg [MAX_LENGTH_WIDTH:0] partial_bytes;

// The total number of data-cycles in the packet
reg [MAX_LENGTH_WIDTH:0] total_data_cycles;

always @* begin

    // How many 'packed full' data cycles will there be?
    whole_data_cycles = (packet_length >> LOG2_DB);

    // If there's a "partial" cycle in the packet, how many bytes will it contain?
    partial_bytes = (packet_length & DB_MASK);

    // This is the total number of data-cycle required for this packet
    total_data_cycles = whole_data_cycles + (partial_bytes != 0);

    // Fill in 'axis_out_tkeep' with either "all bits set" or the final partial value
    axis_out_tkeep = (axis_out_tlast && partial_bytes) ? (1 << partial_bytes)-1 : -1;

end

// The state of our state machine
reg fsm_state;

localparam STATE_IDLE    = 0;
localparam STATE_RUNNING = 1;

// This is a rolling counter that will be replicated across axis_out_tdata
reg[15:0] data;

// axis_out_tlast is asserted on the last cycle of the packet
assign axis_out_tlast = (cycle == total_data_cycles);

// Repeat 'data' across the width of axis_out_tdata
assign axis_out_tdata = {(DW/16){data}};

// We're emitting valid data any time we're in state 1
assign axis_out_tvalid = (resetn == 1) && (fsm_state == STATE_RUNNING);

// We are ready to get new lengths in idle state or when we are in the last
// cycle of transmission and the receiver is ready.
assign axis_in_length_tready = (fsm_state == STATE_IDLE) || (axis_out_tlast && axis_out_tready);


always @(posedge clk) begin

    if (resetn == 0) begin
        fsm_state <= STATE_IDLE;
        data <= 1;
    end

    else case(fsm_state)

        STATE_IDLE: 
        if (axis_in_length_tvalid) begin
            packet_length <= axis_in_length_tdata;
            cycle         <= 1;
            fsm_state     <= STATE_RUNNING;
        end
        else if (!feeding_running) begin
            // If we are in idle state and the feeding is not running anymore,
            // we start counting from 1 again.
            data <=1;
        end

        // Continue sending out the data as long as the receiver is ready.
        STATE_RUNNING:
        if (axis_out_tready) begin
            data  <= data + 1;
            cycle <= cycle + 1;
            // If the last cycle is due and the next length is valid, just get the next
            // length and continue in this state.
            if (axis_out_tlast && axis_in_length_tvalid) begin
                cycle         <= 1;
                packet_length <= axis_in_length_tdata;
            // If the last cycle is due and the new length is not yet valid, wait for the length provider.
            // -> This can happen if the data_player has not too many lengths in
            // his FIFO and the FIFO latency starts throttling us..
            end else if (axis_out_tlast && !axis_in_length_tvalid) begin
                fsm_state <= STATE_IDLE;
            end
        end

      endcase

end

endmodule

