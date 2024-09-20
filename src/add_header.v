//=============================================================================
//               ------->  Revision History  <------
//=============================================================================
//
//   Date     Who   Ver  Changes
//=============================================================================
// 20-Sep-24  FLSO    1  Initial version
//=============================================================================

/*

    This module reads in a data-stream, and computes the length of the incoming
    packages.

    On the output stream, this module writes out the packets that were streamed
    in from the input, with each packet being preceded by a 1-data-cycle header
    that contains the length (in bytes) of the packet that follows.

*/


module add_header # (parameter DW = 128)
(
    input   clk, resetn,

    // The input stream that carries packet data
    // These signals are fed in parallel to the data_fifo and processed by the
    // state machine computing the package length.
    input      [DW-1:0]     axis_data_tdata,
    input      [(DW/8)-1:0] axis_data_tkeep,
    input                   axis_data_tlast,
    input                   axis_data_tvalid,
    output                  axis_data_tready,


    // The output stream
    output reg [DW-1:0]     axis_out_tdata,
    output reg [(DW/8)-1:0] axis_out_tkeep,
    output reg              axis_out_tlast,
    output reg              axis_out_tvalid,
    input                   axis_out_tready
);

//=============================================================================
// one_bits() - This function counts the '1' bits in a field
//=============================================================================
integer i;
function[15:0] one_bits(input[(DW/8)-1:0] field);
begin
    one_bits = 0;
    for (i=0; i<(DW/8); i=i+1) one_bits = one_bits + field[i];
end
endfunction
//=============================================================================


//=============================================================================
// These signals are used to connect the internal FIFOs used to buffer the
// package data and lengths.
//=============================================================================
    // To drain the FIFO that carries packet data
    wire      [DW-1:0]     fifo_out_data_tdata;
    wire      [(DW/8)-1:0] fifo_out_data_tkeep;
    wire                   fifo_out_data_tlast;
    wire                   fifo_out_data_tvalid;
    reg                    fifo_out_data_tready;

    // To feed the FIFO that carries packet lengths
    wire      [DW-1:0]     fifo_in_plen_tdata;
    wire                   fifo_in_plen_tvalid;

    // To drain the FIFO that carries packet lengths
    wire      [DW-1:0]     fifo_out_plen_tdata;
    wire                   fifo_out_plen_tvalid;
    reg                    fifo_out_plen_tready;
//=============================================================================


//=============================================================================
// Every time a valid data-cycle is accepted on the input, accumulate the
// length of the packet thus far.   Note that "plen_accumulator" will never
// include the length of the very last data-cycle in the packet
//=============================================================================

// As a packet passes through, this will accumulate the packet length thus far
reg[15:0] plen_accumulator;

// This is the length of the packet thus far.  On the last data-cycle of
// the packet, this will contain the length of the entire packet
wire [15:0] packet_length = plen_accumulator + one_bits(axis_data_tkeep);

// We write to the "packet length" FIFO (plen_fifo) when the last data-cycle of
// a packet is accepted on the input stream
assign fifo_in_plen_tvalid = axis_data_tvalid & axis_data_tready & axis_data_tlast;

// Just forward the package_length to the FIFO.
assign fifo_in_plen_tdata  = packet_length;
//------------------------------------------------------------------------------

always @(posedge clk) begin
    if (resetn == 0)
        plen_accumulator <= 0;
    else if (axis_data_tvalid & axis_data_tready) begin
        if (axis_data_tlast)
            plen_accumulator <= 0;
        else
            plen_accumulator <= packet_length;
    end
end
//=============================================================================



//=============================================================================
// This state machine waits for a single-data-cycle to be output from the
// packet-length FIFO (plen_fifo), then waits for an entire packet to be output
// from the data FIFO (data_fifo), then repeats.
//
// This is a classic transition function for a Mealy state machine
//=============================================================================
reg fsm_state;
localparam FSM_WAIT_FOR_PLEN = 0;
localparam FSM_WRITE_PACKET  = 1;
//-----------------------------------------------------------------------------
always @(posedge clk) begin

    if (resetn == 0)
        fsm_state <= FSM_WAIT_FOR_PLEN;

    else case (fsm_state)

        // Wait for a header containing the packet-length to be output
        FSM_WAIT_FOR_PLEN:
            if (axis_out_tvalid & axis_out_tready)
                fsm_state <= FSM_WRITE_PACKET;

        // Wait for the entire data-packet to be output
        FSM_WRITE_PACKET:
            if (axis_out_tvalid & axis_out_tready & axis_out_tlast)
                fsm_state <= FSM_WAIT_FOR_PLEN;

    endcase
end
//=============================================================================



//=============================================================================
// Determine the state of our outputs in each state (including reset)
//
// This is a textbook example of a Mealy state machine
//=============================================================================
always @* begin

    if (resetn == 0) begin
        axis_out_tdata   = 0;
        axis_out_tkeep   = 0;
        axis_out_tlast   = 0;
        axis_out_tvalid  = 0;
        fifo_out_data_tready = 0;
        fifo_out_plen_tready = 0;
    end

    else case(fsm_state)

    // In this state, axis_out is fed from fifo_out_plen
    FSM_WAIT_FOR_PLEN:
        begin
            axis_out_tdata   = fifo_out_plen_tdata;
            axis_out_tkeep   = -1;
            axis_out_tlast   = 0;
            axis_out_tvalid  = fifo_out_plen_tvalid;
            fifo_out_data_tready = 0;
            fifo_out_plen_tready = axis_out_tready;
        end

    // In this state, axis_out is fed from fifo_out_data
    FSM_WRITE_PACKET:
        begin
            axis_out_tdata   = fifo_out_data_tdata;
            axis_out_tkeep   = fifo_out_data_tkeep;
            axis_out_tlast   = fifo_out_data_tlast;
            axis_out_tvalid  = fifo_out_data_tvalid;
            fifo_out_data_tready = axis_out_tready;
            fifo_out_plen_tready = 0;
        end

    endcase

end
//=============================================================================



//=============================================================================
// FIFO used to buffer the full incoming packges until we got the the length of
// the packages.
//=============================================================================
xpm_fifo_axis #(
  .TDATA_WIDTH(DW),               // DECIMAL
  .FIFO_DEPTH(2048),              // DECIMAL
  .CDC_SYNC_STAGES(3),            // DECIMAL
  .CLOCKING_MODE("common_clock"), // String
  .FIFO_MEMORY_TYPE("auto"),      // String
  .PACKET_FIFO("false")           // String
)
data_fifo (
    // Clock and reset
.s_aclk   (clk   ),
.m_aclk   (clk   ),
.s_aresetn(resetn),

// The input of this FIFO is the AXIS_RDMX interface
.s_axis_tdata (axis_data_tdata),
.s_axis_tkeep (axis_data_tkeep),
.s_axis_tlast (axis_data_tlast),
.s_axis_tvalid(axis_data_tvalid),
.s_axis_tready(axis_data_tready),

// The output of this FIFO drives the "W" channel of the M_AXI interface
.m_axis_tdata (fifo_out_data_tdata),
.m_axis_tkeep (fifo_out_data_tkeep),
.m_axis_tvalid(fifo_out_data_tvalid),
.m_axis_tlast (fifo_out_data_tlast),
.m_axis_tready(fifo_out_data_tready),

// Unused input stream signals
.s_axis_tdest(),
.s_axis_tid  (),
.s_axis_tstrb(),
.s_axis_tuser(),

// Unused output stream signals
.m_axis_tdest(),
.m_axis_tid  (),
.m_axis_tstrb(),
.m_axis_tuser(),

// Other unused signals
.almost_empty_axis(),
.almost_full_axis(),
.dbiterr_axis(),
.prog_empty_axis(),
.prog_full_axis(),
.rd_data_count_axis(),
.sbiterr_axis(),
.wr_data_count_axis(),
.injectdbiterr_axis(),
.injectsbiterr_axis()
);
//=============================================================================



//=============================================================================
// FIFO used to buffer the lengths of the packages. This FIFO is needed since
// inserting the extra cycle for the package header produces some back pressure.
// Therefore the data_fifo can hold more than one package so we have to buffer
// the associated lengths too.
//=============================================================================
xpm_fifo_axis #(
  .TDATA_WIDTH(DW),               // DECIMAL
  .FIFO_DEPTH(2048),              // DECIMAL
  .CDC_SYNC_STAGES(3),            // DECIMAL
  .CLOCKING_MODE("common_clock"), // String
  .FIFO_MEMORY_TYPE("auto"),      // String
  .PACKET_FIFO("false")           // String
)
plen_fifo (
    // Clock and reset
.s_aclk   (clk   ),
.m_aclk   (clk   ),
.s_aresetn(resetn),

// The input of this FIFO is the AXIS_RDMX interface
.s_axis_tdata (fifo_in_plen_tdata),
.s_axis_tvalid(fifo_in_plen_tvalid),

// The output of this FIFO drives the "W" channel of the M_AXI interface
.m_axis_tdata (fifo_out_plen_tdata),
.m_axis_tvalid(fifo_out_plen_tvalid),
.m_axis_tready(fifo_out_plen_tready),

// Unused input stream signals
.s_axis_tkeep (),
.s_axis_tlast (),
.s_axis_tdest(),
.s_axis_tid  (),
.s_axis_tstrb(),
.s_axis_tuser(),
// We do not use this signal. Both buffers have the same size and plen will
// contain only one cycle of data of data package stored in the data fifo. So
// if the data fifo is full, the plen fifo will still have plenty of space.
.s_axis_tready(),

// Unused output stream signals
.m_axis_tkeep (),
.m_axis_tlast (),
.m_axis_tdest(),
.m_axis_tid  (),
.m_axis_tstrb(),
.m_axis_tuser(),

// Other unused signals
.almost_empty_axis(),
.almost_full_axis(),
.dbiterr_axis(),
.prog_empty_axis(),
.prog_full_axis(),
.rd_data_count_axis(),
.sbiterr_axis(),
.wr_data_count_axis(),
.injectdbiterr_axis(),
.injectsbiterr_axis()
);
//=============================================================================
				
endmodule
