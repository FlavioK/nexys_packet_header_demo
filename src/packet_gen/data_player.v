//=============================================================================
//               ------->  Revision History  <------
//=============================================================================
//
//   Date     Who   Ver  Changes
//=============================================================================
// 27-Sep-24  FLSO    1  Initial version
//=============================================================================
/*

    This module can be used as a data feeder. The data has to be recorded/loaded
    first, by adding the elements one after the other. Afterwards, the
    replay_enable signal can be asserted and the data_player will start and keep
    outputting the stored data elements one after the other until replay_enable
    is deasserted.

    If the replay_enable is deasserted the data_player will continue the replay
    until the current pass is completed.

    New data can only be loaded if replay_idle is 1, otherwise it will have
    no effect.
*/
module data_player # (parameter DW=16, CAPACITY=1024)
(
    input   clk, resetn,

    // =================================================
    // Controlling and recording interface
    // =================================================

    // The replay is started if replay_enable is 1 and size is > 0
    input                           replay_enable,

    // 1 if replay is idle. Otherwise 0
    output                          replay_idle,

    // New data element
    input [DW-1:0]                  axis_in_tdata,

    // Signal to tell that the currently applied data value should be recorded.
    input                           axis_in_tvalid,

    // Signal that we can accept new data. 1 means we can accept a new element.
    // Only 1 if we still hvae anough space and if replay_idle is 1.
    output reg                      axis_in_tready,

    // Retuns the number of data elements held by the FIFO.
    output reg [31:0]               size,

    // If set to true, all recordings are cleared.
    // Works only if replay_idle is 1.
    input                           clear,
    // -------------------------------------------------

    // =================================================
    // Replay interface
    // =================================================

    // The current data from the replay.
    output reg [DW-1:0]         axis_out_tdata,

    // Validity of the data
    output reg                  axis_out_tvalid,

    // The current data from the replay can be consumed.
    input                       axis_out_tready
    // -------------------------------------------------
);

//=============================================================================
// These signals are used to connect the internal FIFO
//=============================================================================

// Counter to reset the FIFO. 4 bits wide so we can keep the reset low for 16
// cycles.
reg  [3:0]    fifo_reset_counter;
wire          fifo_reset;

// To feed the fifo
reg  [DW-1:0] fifo_data_in_tdata;
reg           fifo_data_in_tvalid;
wire          fifo_data_in_tready;

// To drain the fifo
wire [DW-1:0] fifo_data_out_tdata;
wire          fifo_data_out_tvalid;
reg           fifo_data_out_tready;
//=============================================================================

// If we get the resetn signal, we do not keep the fifo in reset for 16 cycles
// since we expect the upper layers to take care of this.
// Otherwise if we use the FIFO reset to clear the contained data, we have to
// wait for 16 cycles until fifo_reset_counter is 0 again.
// More info regarding the 16 cycles can be found here:
// https://docs.amd.com/r/en-US/pg085-axi4stream-infrastructure/Resets
// Reset the fifo if either resetn is 0 or the fifo_reset_counter is != 0
assign fifo_resetn = (resetn && (fifo_reset_counter == 0));

//=============================================================================
// These signals connect the FIFOs tready, and clear signals with the current
// state we are in.
//=============================================================================

// Reset the fifo in case we get a reset signal or if we get the clear signal
// and the replay is in idle.
// clear the fifo only if we receive the clear signal and are in recording state.
assign fifo_clearn = !(clear && replay_idle); // ===> reset should be at least 16 cycles for xilinx IPs.

// Indicates that we still have space available.
// Reason for this check is that the FIFO seems to be able to hold 2 elements
// more than CAPACITY elements. If we even fill these two elements up, the
// replay mechanism fails due to not enough space while back feeding.
assign space_available = (size < CAPACITY);
//=============================================================================

//=============================================================================
// This state machine is used control the current data_player state.
// If decides when we switch to the REPLAY or RECORDING states and keeps track
// of the current replay position and FIFO size.
//=============================================================================

// FIFO modifications are allowed.
localparam STATE_IDLE   = 0;

// Replay is running. No FIFO modifications are allowed.
localparam STATE_REPLAY = 1;

// The state of the fsm. Can be STATE_IDLE or STATE_REPLAY
reg fsm_state;

// Current replay position
reg [31:0] replay_pos;

// replay_idle is 1 if we are in STATE_IDLE
assign replay_idle = (fsm_state == STATE_IDLE);

always @(posedge clk) begin

    // Always decrement the reset counters to 0
    if(fifo_reset_counter > 0) fifo_reset_counter <= fifo_reset_counter - 1;

    if (resetn == 0) begin
        fsm_state          <= STATE_IDLE;
        replay_pos         <= 0;
        size               <= 0;
        fifo_reset_counter <= 0;
    end
    else case(fsm_state)

        STATE_IDLE:
            // We can enter the replay state if the fifo is out of reset and we
            // have at least 1 data element stored.
            if (replay_enable && fifo_resetn && (size > 0)) begin
                fsm_state  <= STATE_REPLAY;
                replay_pos  <= 0;

            end else if (clear) begin
                // If clear is requested, set the size to 0
                size <= 0;

                // Reset the FIFO for 16 cycles.
                fifo_reset_counter = -1;

            // We can only add new data in case the fifo is out of reset.
            end else if (fifo_resetn && axis_in_tvalid && fifo_data_in_tready && space_available) begin
                // We just keep track of the data we are recording here.
                size <= size + 1;
            end

        STATE_REPLAY:
            // Go to the next play back position in case we got the confirmation
            // from the consumer.
            if (axis_out_tready && axis_out_tvalid) begin

                // Check that we did not reach the end of the recording yet.
                // This has to be size-1 since the replay pos increment happens 1 clock cycle delayed.
                // size = 4
                // (wrap-around at size-1)    |
                //                            v
                // replay_pos    : 0  1  2  3   0  1  2  3 ...
                // element@output: A  B  C  D   A  B  C  D ...
                if(replay_pos < (size-1)) begin
                    replay_pos <= replay_pos + 1;
                end

                // Start from the beginning again if we reached the end
                // of one replay pass and we are still allowed to run.
                else if(replay_enable) begin
                    replay_pos <= 0;

                // Otherwise we are safe to switch now to the idle state.
                end else begin
                    fsm_state <= STATE_IDLE;
                end 
            end
    endcase
end

//=============================================================================
// This always block routes the data to the output and into the FIFO.
//=============================================================================
always @* begin

    if (resetn == 0) begin
        axis_out_tvalid      = 0;
        axis_out_tdata       = 0;
        axis_in_tready       = 0;
        fifo_data_in_tvalid  = 0;
        fifo_data_in_tdata   = 0;
        fifo_data_out_tready = 0;
    end

    else case(fsm_state)

    // In this state, the data FIFO is fed from axis_in
    STATE_IDLE:
        begin

            // We stop outputting useful data in this state.
            axis_out_tvalid      = 0;
            axis_out_tdata       = 0;
            fifo_data_out_tready = 0;

            // Pipe in the data to record.
            fifo_data_in_tdata  = axis_in_tdata;
            fifo_data_in_tvalid = axis_in_tvalid;

            // We are ready to accept data if the FIFO is out of reset, the FIFO
            // is ready to accept data, and we still have space available.
            axis_in_tready      = fifo_resetn && fifo_data_in_tready && space_available;
        end

    // In this state, axis_out is fed from the FIFO
    STATE_REPLAY:
        begin

            // We disallow feed new length data in replay mode.
            axis_in_tready = 0;

            // We are replaying now. Feed the output accordingly!
            axis_out_tvalid      = fifo_data_out_tvalid;
            axis_out_tdata       = fifo_data_out_tdata;

            // And let us serve the tready signal only from the consumer side.
            // the fifo input tready should always be fine since we just take
            // an element out and place it again at the back.
            fifo_data_out_tready = axis_out_tready;

            // Feed the loopback! But only in case we are sure that the
            // consumer eat out new data.
            fifo_data_in_tvalid = axis_out_tvalid && axis_out_tready;
            fifo_data_in_tdata  = axis_out_tdata;
        end
    endcase
end




//=============================================================================
// FIFO used to buffer the packet lenghts until we got the the length of
// the packages.
//=============================================================================
xpm_fifo_axis #(
  .TDATA_WIDTH(DW),               // DECIMAL
  .FIFO_DEPTH(CAPACITY),          // DECIMAL
  .CDC_SYNC_STAGES(3),            // DECIMAL
  .CLOCKING_MODE("common_clock"), // String
  .FIFO_MEMORY_TYPE("auto"),      // String
  .PACKET_FIFO("false")           // String
)
packet_length_fifo (

// Clock and reset
.s_aclk   (clk   ),
.m_aclk   (clk   ),

.s_aresetn( fifo_resetn ),

// The input of this FIFO is either the FIFO output or the modules length input.
.s_axis_tdata (fifo_data_in_tdata),
.s_axis_tvalid(fifo_data_in_tvalid),
.s_axis_tready(fifo_data_in_tready),

// The output of this FIFO drives the output of this module and its own input.
.m_axis_tdata (fifo_data_out_tdata),
.m_axis_tvalid(fifo_data_out_tvalid),
.m_axis_tready(fifo_data_out_tready),

// Unused input stream signals
.s_axis_tkeep (),
.s_axis_tlast (),
.s_axis_tdest(),
.s_axis_tid  (),
.s_axis_tstrb(),
.s_axis_tuser(),

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

