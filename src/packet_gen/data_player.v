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
    first, by adding the elements one after the other. Afterwards, the start
    signal can be applied and the data_player will start and keep outputting the
    stored data elements one after the other until the start signal is applied
    again.

    If the start signal is applied while feeding_status is 1, the data_player
    will continue the playback until the current pass is completed.

    New data can only be loaded if feeding_status is 0, otherwise it will have
    no effect.
*/
module data_player # (parameter DW=16, CAPACITY=1024)
(
    input   clk, resetn,

    // =================================================
    // Controlling and recording interface
    // =================================================
    // We start generating packets when this is asserted
    input                           start,
    // Feeding status. If True, replay is in progress.
    output reg                      player_state,

    // New data element
    input [DW-1:0]                  axis_in_tdata,
    // Signal to tell that the currently applied data value should be recorded.
    input                           axis_in_tvalid,
    // Signal that we can accept new data.
    output reg                      axis_in_tready,

    // Retuns the number of data recordings.
    output reg [31:0]               size,

    // If set to true, all recordings are cleared.
    // Works only if out_clear_ready is 1.
    input                           clear,
    output                          clear_ready,
    // -------------------------------------------------

    // =================================================
    // Playback interface
    // =================================================
    // The current data from the playback.
    output reg [DW-1:0]         axis_out_tdata,
    // The current data from the playback.
    output reg                  axis_out_tvalid,
    // This is here to satisfy the ILA
    output                      axis_out_tlast,
    // The current data from the playback can be consumed.
    input                       axis_out_tready
    // -------------------------------------------------
);

// The generated length always just consist of 1 cycle of data.
// Therefore tlast can always be asserted with tvalid.
assign  axis_out_tlast = axis_out_tvalid;

// The two statuses we can be in.
localparam STATE_RECORDING = 0;
localparam STATE_REPLAY    = 1;

//=============================================================================
// These signals are used to connect the internal FIFO
//=============================================================================

// To feed the fifo
reg        [DW-1:0]    fifo_data_in_tdata;
reg                    fifo_data_in_tvalid;
wire                   fifo_data_in_tready;

// To drain the fifo
wire      [DW-1:0]     fifo_data_out_tdata;
wire                   fifo_data_out_tvalid;
reg                    fifo_data_out_tready;
//=============================================================================


//=============================================================================
// These signals connect the FIFOs tready, and clear signals with the current
// state we are in.
//=============================================================================

// Clear can only be used in recording state
assign clear_ready       = (player_state == STATE_RECORDING);

// Reset the fifo in case we get a reset signal or if we get the clear signal
// and the player is in recording state.
// clear the fifo only if we receive the clear signal and are in recording state.
assign fifo_clearn = !(clear && clear_ready);

// We only allow recording if the fifo is ready and size did not exceed yet the CAPACITY.
// Reason for this check is that the FIFO seems to be able to hold 2 elements
// more than CAPACITY elements. If we even fill these two elements up, the
// replay mechanism fails due to not enough space while back feeding.
assign recording_tready = fifo_data_in_tready && (size < CAPACITY);
//=============================================================================

//=============================================================================
// This state machine is used control the current data_player state.
// If decides when we switch to the REPLAY or RECORDING states and keeps track
// of the current recording position and FIFO size.
//=============================================================================

// Used to latch the request to switch back to recording state.
reg request_recording;
// Current playback position
reg [31:0] playback_pos;

always @(posedge clk) begin

    // If we are in replay mode and receive a start signal, we request the state
    // machine to switch to the recording state as soon as possible.
    if(start && player_state == STATE_REPLAY) request_recording <= 1;

    if (resetn == 0) begin
        player_state      <= STATE_RECORDING;
        request_recording <= 0;
        playback_pos      <= 0;
        size              <= 0;
    end
    else case(player_state)

        STATE_RECORDING:
            // We can enter replay start if we get the start signal and have at
            // least 1 length stored.
            if (start && (size > 0)) begin
                player_state  <= STATE_REPLAY;
                playback_pos  <= 0;

            end else if (clear) begin
                // If clear is requested, set the size to 0
                size <= 0;
            end else if (axis_in_tvalid && recording_tready) begin
                // We just keep track of the data we are recording here.
                size <= size + 1;
            end

        STATE_REPLAY:
            // Go to the next play back position in case we got the confirmation from the consumer.
            if (axis_out_tready) begin
                // If a switch to recording got requested and we are at the end pos
                // of the playback, we switch to the recording state.
                if (request_recording && (playback_pos == (size-1))) begin
                    request_recording <= 0;
                    player_state      <=  STATE_RECORDING;
                end
                // Otherwise just increment the play back position
                else begin
                    // Keep track of the current playback position, so we can allow the
                    // switch to the recording state at the right time.
                    // We are at position size - 1 which means we went through a whole loop.
                    // The -1 since the tracking of the current position is one
                    // cycle behind and we increment the current while outputting it.
                    if (playback_pos == (size-1)) begin 
                        playback_pos <= 0;
                    end else begin
                        playback_pos <= playback_pos + 1;
                    end
                end
            end
    endcase
end

//=============================================================================
// This always block takes care of the correct data routing based on the
// data_player state we are in.
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

    else case(player_state)

    // In this state, axis_out is fed from fifo_out_plen
    STATE_RECORDING:
        begin
            // We stop outputting useful data in this state.
            axis_out_tvalid      = 0;
            axis_out_tdata       = 0;
            fifo_data_out_tready = 0;

            // Pipe in the data to record.
            fifo_data_in_tdata  = axis_in_tdata;
            fifo_data_in_tvalid = axis_in_tvalid;
            axis_in_tready      = recording_tready;
        end

    // In this state, axis_out is fed from fifo_out_data
    STATE_REPLAY:
        begin
            // We disallow feed new length data in playback mode.
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
            fifo_data_in_tvalid = fifo_data_out_tvalid && axis_out_tready;
            fifo_data_in_tdata  = fifo_data_out_tdata;
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
.s_aresetn(fifo_clearn && resetn),

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

