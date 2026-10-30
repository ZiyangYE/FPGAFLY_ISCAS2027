module command_router (
    input wire clk,
    input wire rst,
    input wire request,
    input wire [511:0] packet,
    output reg acknowledge = 0,
    output reg [511:0] response = 0,
    output reg busy = 0,
    output reg [511:0] command = 0,
    output reg debug_request = 0,
    input wire debug_ack,
    input wire [511:0] debug_response,
    output reg load_request = 0,
    input wire load_ack,
    input wire [511:0] load_response,
    output reg core_request = 0,
    input wire core_ack,
    input wire [511:0] core_response,
    output reg loader_selected = 0,
    output reg core_selected = 0
);

    (* syn_preserve = 1 *) reg [2:0] request_sync = 0;
    reg dispatch_pending = 0;

    wire capture_packet = !busy && request_sync[2] != acknowledge;
    wire complete = core_selected ? core_ack == core_request :
                    loader_selected ? load_ack == load_request : debug_ack == debug_request;
    wire capture_response = !capture_packet && !dispatch_pending && busy && complete;
    wire [511:0] reply = core_selected ? core_response :
                        loader_selected ? load_response : debug_response;

    // The board_clk side holds the packet until it receives the reply toggle.
    // Capture the packet, dispatch it and return the reply on separate UI clocks.
    always @(posedge clk) begin
        request_sync <= {request_sync[1:0], request};
        if (rst) begin
            busy <= 0;
            dispatch_pending <= 0;
            acknowledge <= request_sync[2];
            debug_request <= debug_ack;
            load_request <= load_ack;
            core_request <= core_ack;
        end else if (capture_packet) begin
            busy <= 1;
            dispatch_pending <= 1;
        end else if (dispatch_pending) begin
            loader_selected <= command[39:32] >= 16;
            core_selected <= command[39:32] >= 32;
            dispatch_pending <= 0;
            if (command[39:32] >= 32) core_request <= ~core_request;
            else if (command[39:32] >= 16) load_request <= ~load_request;
            else debug_request <= ~debug_request;
        end else if (busy && complete) begin
            acknowledge <= request_sync[2];
            busy <= 0;
        end
    end

    // Use a separate enable per word to limit fanout; all words latch on the same clock.
    genvar word_index;

    generate
        for (word_index = 0; word_index < 16; word_index = word_index + 1) begin : words
            wire packet_enable  /* synthesis syn_keep=1 */;
            wire response_enable  /* synthesis syn_keep=1 */;
            LUT2 #(
                .INIT(4'h8)
            ) packet_gate (
                .I0(!rst),
                .I1(capture_packet),
                .F (packet_enable)
            );

            LUT2 #(
                .INIT(4'h8)
            ) response_gate (
                .I0(!rst),
                .I1(capture_response),
                .F (response_enable)
            );

            always @(posedge clk) begin
                if (packet_enable) command[word_index*32+:32] <= packet[word_index*32+:32];
                if (response_enable) response[word_index*32+:32] <= reply[word_index*32+:32];
            end
        end
    endgenerate

endmodule
