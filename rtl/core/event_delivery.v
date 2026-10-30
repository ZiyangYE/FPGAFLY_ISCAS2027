// Read the due queue and stream each descriptor's edges to the state array.
module event_delivery (
    input clk, rst, clear, start,
    input [4:0] slot,
    input [17:0] count,
    output done,
    output direct_valid,
    output reg [31:0] direct_address,
    input direct_ready, direct_response,
    input [255:0] rd_data,
    output reg stream_start = 0,
    output reg [31:0] stream_base,
    output reg [23:0] stream_lines,
    input edge_take, event_done,
    output reg [13:0] edge_left = 0,
    output reg [1:0] edge_lane = 0,
    (* syn_preserve=1 *) output reg active = 0,
    output reg [31:0] total_edges = 0
);
    localparam IDLE=0, NEXT=1, REQUEST=2, RESPONSE=3, LOAD=4;
    localparam SELECT=5, EDGES=6, RUN=7, ADVANCE=8, DONE=9;
    reg [3:0] state = IDLE;
    reg [17:0] index;
    reg [255:0] line;
    reg [63:0] descriptor;
    reg [13:0] remaining;
    wire [6:0] slot_scaled = {2'b0, slot} + {1'b0, slot, 1'b0};

    assign direct_valid = state == REQUEST;
    assign done = state == DONE;

    always @(posedge clk) begin
        stream_start <= 0;
        if (rst) begin
            state <= IDLE;
            active <= 0;
        end else case (state)
            IDLE: if (start) begin
                index <= 0;
                state <= NEXT;
            end
            NEXT:
                if (index == count) state <= DONE;
                else if (index[1:0] == 0) begin
                    direct_address <= {4'h2, slot_scaled, index[17:2], 5'b0};
                    state <= REQUEST;
                end else state <= SELECT;
            REQUEST: if (direct_ready) state <= RESPONSE;
            RESPONSE: if (direct_response) begin
                line <= rd_data;
                state <= LOAD;
            end
            LOAD: state <= SELECT;
            SELECT: begin
                descriptor <= line[index[1:0]*64+:64];
                state <= EDGES;
            end
            EDGES:
                if (descriptor[38:25] == 0) state <= ADVANCE;
                else begin
                    edge_lane <= descriptor[1:0];
                    edge_left <= descriptor[38:25];
                    remaining <= descriptor[38:25];
                    stream_base <= {4'b0, descriptor[24:2], 5'b0};
                    stream_lines <= ({10'b0, descriptor[38:25]} + descriptor[1:0] + 3) >> 2;
                    stream_start <= 1;
                    active <= 1;
                    state <= RUN;
                end
            RUN: begin
                if (edge_take) begin
                    edge_left <= edge_left - 1'b1;
                    edge_lane <= edge_lane + 1'b1;
                end
                if (event_done) begin
                    remaining <= remaining - 1'b1;
                    if (remaining == 1) begin
                        active <= 0;
                        state <= ADVANCE;
                    end
                end
            end
            ADVANCE: begin
                index <= index + 1'b1;
                state <= NEXT;
            end
            DONE: state <= IDLE;
        endcase

        if (clear) total_edges <= 0;
        else if (!rst && state == RUN && event_done) total_edges <= total_edges + 1'b1;
    end
endmodule
