// Sequence frame commands and return their results to the host.
module frame_control #(
    parameter START_T=2000, PREFETCH=64
) (
    input clk, rst, calibrated, request,
    input [511:0] packet,
    output reg acknowledge = 0,
    output reg [511:0] response = 0,
    output reg failed = 0,
    output reg resume = 0,
    output busy, clear_frame, boot_active, run_start, running, classify, query,
    output reg [31:0] score_page = 0,
    output reg [17:0] query_id,
    input boot_done, run_done, class_done, sample_done,
    input dense_failed, event_failed,
    input [3:0] winner,
    input [255:0] score_data,
    input [40:0] sample_value,
    input [6:0] fire_queue_peak,
    input [11:0] timestep,
    input [31:0] total_spikes, total_edges,
    input [21:0] pending_peak, pending_events,
    input [17:0] queue_peak,
    input [$clog2(PREFETCH):0] stream_peak
);
    localparam IDLE=0, BOOT_START=1, BOOT=2, RUN_START=3, RUN=4;
    localparam CLASSIFY=5, CLASS_WAIT=6, FINISH=7, SCORES=8, QUERY=9, QUERY_WAIT=10;
    reg [3:0] state = IDLE;
    reg [31:0] command_id = 0;
    reg [63:0] cycles = 0;
    reg started = 0;
    reg initialized = 0;
    assign clear_frame = state == BOOT_START;
    assign boot_active = state == BOOT_START || state == BOOT;
    assign busy = state != IDLE;

    assign run_start = state == RUN_START;
    assign running = state == RUN;
    assign classify = state == CLASSIFY;
    assign query = state == QUERY;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            initialized <= 0;
            resume <= 0;
            acknowledge <= request;
            response <= 0;
        end else begin
            if (busy) cycles <= cycles + 1'b1;
            case (state)
                IDLE: if (request != acknowledge) begin
                    command_id <= packet[63:32];
                    if (packet[39:32] == 33) begin
                        score_page <= packet[95:64];
                        state <= SCORES;
                    end else if (packet[39:32] == 34) begin
                        query_id <= packet[81:64];
                        state <= QUERY;
                    end else begin
                        cycles <= 0;
                        started <= 0;
                        failed <= 0;
                        if (packet[31:0] != 32'h44445233 || !calibrated ||
                            (packet[39:32] != 35 && packet[39:32] != 36) ||
                            (packet[39:32] == 36 && !initialized)) begin
                            failed <= 1;
                            state <= FINISH;
                        end else begin
                            started <= 1;
                            resume <= packet[39:32] == 36;
                            state <= BOOT_START;
                        end
                    end
                end
                BOOT_START: state <= BOOT;
                BOOT: if (boot_done) begin
                    initialized <= 1;
                    state <= RUN_START;
                end
                RUN_START: state <= RUN;
                RUN: if (run_done) state <= CLASSIFY;
                CLASSIFY: state <= CLASS_WAIT;
                CLASS_WAIT: if (class_done) state <= FINISH;
                FINISH: begin
                    response <= 0;
                    response[31:0] <= 32'h44445233;
                    response[63:32] <= command_id;
                    response[95:64] <= {27'b0, failed, failed, calibrated, 1'b1, 1'b0};
                    response[127:96] <= {9'b0, fire_queue_peak, 15'b0, failed};
                    response[159:128] <= started ? timestep : START_T;
                    response[191:160] <= started ? total_spikes : 32'b0;
                    response[223:192] <= started ? total_edges : 32'b0;
                    response[287:256] <= {28'b0, winner};
                    response[351:288] <= cycles;
                    response[383:352] <= {10'b0, pending_peak};
                    response[415:384] <= {14'b0, queue_peak};
                    response[447:416] <= stream_peak;
                    response[479:448] <= {10'b0, pending_events};
                    response[511:480] <= 100000000;
                    acknowledge <= request;
                    state <= IDLE;
                end
                SCORES: begin
                    response <= 0;
                    response[31:0] <= 32'h44445233;
                    response[63:32] <= command_id;
                    response[95:64] <= 6;
                    response[511:256] <= score_data;
                    acknowledge <= request;
                    state <= IDLE;
                end
                QUERY: state <= QUERY_WAIT;
                QUERY_WAIT: if (sample_done) begin
                    response <= 0;
                    response[31:0] <= 32'h44445233;
                    response[63:32] <= command_id;
                    response[95:64] <= 6;
                    response[296:256] <= sample_value;
                    acknowledge <= request;
                    state <= IDLE;
                end
            endcase
            if (state == RUN && (dense_failed || event_failed)) begin
                initialized <= 0;
                failed <= 1;
                state <= FINISH;
            end
        end
    end
endmodule
