// Buffer prefetched DDR data in synchronous RAM; bypass RAM when the queue is empty.
module memory_reader #(
    parameter DEPTH = 48,
    AW = $clog2(DEPTH)
) (
    input wire clk,
    input wire rst,
    input wire start,
    input wire [31:0] base,
    input wire [23:0] lines,
    output reg busy = 0,
    output reg done = 0,
    output wire request,
    input wire ready,
    output reg [31:0] address,
    input wire response_valid,
    input wire [255:0] response_data,
    output wire valid,
    input wire take,
    output wire [255:0] data,
    output reg [AW:0] peak = 0,
    input wire pixel_mode,
    input wire pixel_write,
    input wire [9:0] pixel_write_address,
    input wire [17:0] pixel_write_data,
    input wire pixel_read,
    input wire [9:0] pixel_read_address,
    output wire [17:0] pixel_read_data,
    input wire input_write,
    input wire [9:0] input_address,
    input wire [255:0] input_data,
    output wire input_ready
);

    // Queue entries occupy words 0..DEPTH-1. Input records and pixels start at 128.
    reg input_mode = 0;
    reg [9:0] input_head = 0;
    wire input_start = start && !busy && base == 32'h10990000;
    wire input_fetch = input_start && lines != 0 || input_mode && pop && consume_left > 1;
    wire [9:0] input_read_word = input_start ? 10'd128 : input_head + 10'd129;
    wire [9:0] input_write_word = input_address + 10'd128;
    wire [9:0] pixel_write_word = pixel_write_address + 10'd128;
    wire [9:0] pixel_read_word = pixel_read_address + 10'd128;
    wire [155:0] input_packed;
    assign input_ready = !response_valid;

    reg [AW-1:0] head = 0, tail = 0;
    wire [AW-1:0] next_head = head == DEPTH - 1 ? {AW{1'b0}} : head + 1'b1;
    reg [AW:0] reserved = 0, available = 0;
    reg has_data = 0, single_line = 0;
    reg [23:0] issue_left, consume_left;
    assign request = busy && !input_mode && issue_left != 0 && reserved < DEPTH;
    wire issue = request && ready;
    assign valid = has_data;
    wire pop = valid && take;
    reg pulse_words = 0, bypass = 0;
    reg  [163:0] arrival;
    wire [163:0] fields64;
    wire [155:0] fields26;
    wire [255:0] expanded64, expanded26;
    wire [163:0] packed_response = pulse_words ? {8'b0, fields26} :
        fields64;
    wire [179:0] memory_data;
    wire [179:0] memory_write = {16'b0, packed_response};
    wire [163:0] front = input_mode ? memory_data[163:0] :
        bypass ? arrival : memory_data[163:0];
    // With two or more queued lines, the next head is already in RAM.
    // READ_MODE=0 registers the next head at the RAM output.
    wire fetch = !input_mode && pop && !single_line;
    genvar bank, field;

    generate
        for (bank = 0; bank < 10; bank = bank + 1) begin : banks
            wire [35:0] native_data;
            assign memory_data[bank*18+:18] = native_data[17:0];
            wire owned_by_pixels = bank == 9 && pixel_mode;
            wire store_input = bank < 9 && input_write && input_ready;
            wire load_input = bank < 9 && input_fetch;
            wire [179:0] input_bits = {24'b0, input_packed};
            wire [13:0] bank_write_address = owned_by_pixels ?
            {pixel_write_word,4'b0011} : store_input ?
            {input_write_word,4'b0011} : {{(10-AW){1'b0}},tail,4'b0011};
            wire [13:0] bank_read_address = owned_by_pixels ?
            {pixel_read_word,4'b0000} : load_input ?
            {input_read_word,4'b0000} : {{(10-AW){1'b0}},next_head,4'b0000};
            if (bank == 9) assign pixel_read_data = native_data[17:0];
            SDPX9B #(
                .BIT_WIDTH_0(18),
                .BIT_WIDTH_1(18),
                .READ_MODE  (1'b0),
                .BLK_SEL_0  (3'b000),
                .BLK_SEL_1  (3'b000)
            ) memory (
                .DO(native_data),
                .DI(owned_by_pixels ? {18'b0,pixel_write_data} :
                    store_input ? {18'b0,input_bits[bank*18+:18]} :
                    {18'b0,memory_write[bank*18+:18]}),
                .BLKSELA(3'b000),
                .BLKSELB(3'b000),
                .ADA(bank_write_address),
                .ADB(bank_read_address),
                .CLKA(clk),
                .CLKB(clk),
                .CEA(owned_by_pixels ? pixel_write : response_valid || store_input),
                .CEB(owned_by_pixels ? pixel_read : fetch || load_input),
                .OCE(1'b1),
                .RESET(1'b0)
            );

        end
        for (field = 0; field < 4; field = field + 1) begin : format64
            assign fields64[field*41+:41] = response_data[field*64+:41];
            assign expanded64[field*64+:64] = {23'b0, front[field*41+:41]};
        end
        for (field = 0; field < 6; field = field + 1) begin : format26
            assign input_packed[field*26+:26] = input_data[field*32+:26];
            assign fields26[field*26+:26] = response_data[field*32+:26];
            assign expanded26[field*32+:32] = {6'b0, front[field*26+:26]};
        end
        assign expanded26[255:192] = 0;
    endgenerate

    assign data = pulse_words ? expanded26 : expanded64;

    always @(posedge clk) begin
        done <= 0;
        if (rst) begin
            busy <= 0;
            input_mode <= 0;
            input_head <= 0;
            head <= 0;
            tail <= 0;
            reserved <= 0;
            available <= 0;
            has_data <= 0;
            single_line <= 0;
            peak <= 0;
            bypass <= 0;
        end else if (start && !busy) begin
            busy <= lines != 0;
            done <= lines == 0;
            address <= base;
            input_mode <= base == 32'h10990000;
            input_head <= 0;
            pulse_words <= (base == 32'h10980000 || base == 32'h10990000);
            issue_left <= lines;
            consume_left <= lines;
            head <= 0;
            tail <= 0;
            reserved <= 0;
            available <= 0;
            has_data <= input_start && lines != 0;
            single_line <= 0;
        end else if (input_mode) begin
            if (pop) begin
                input_head <= input_head + 1'b1;
                consume_left <= consume_left - 1'b1;
                if (consume_left == 1) begin
                    busy <= 0;
                    done <= 1;
                    has_data <= 0;
                end
            end
        end else begin
            if (response_valid && (!has_data || (pop && single_line))) begin
                arrival <= packed_response;
                bypass <= 1;
            end else if (fetch) bypass <= 0;
            if (issue) begin
                address <= address + 32;
                issue_left <= issue_left - 1'b1;
            end
            if (response_valid) tail <= tail == DEPTH - 1 ? {AW{1'b0}} : tail + 1'b1;
            if (pop) begin
                head <= next_head;
                consume_left <= consume_left - 1'b1;
                if (consume_left == 1) begin
                    busy <= 0;
                    done <= 1;
                end
            end
            case ({
                issue, pop
            })
                2'b10: begin
                    reserved <= reserved + 1'b1;
                    if (reserved >= peak) peak <= reserved + 1'b1;
                end
                2'b01: reserved <= reserved - 1'b1;
            endcase
            case ({
                response_valid, pop
            })
                2'b10: begin
                    available <= available + 1'b1;
                    has_data <= 1;
                    single_line <= available == 0;
                end
                2'b01: begin
                    available <= available - 1'b1;
                    has_data <= available > 1;
                    single_line <= available == 2;
                end
            endcase
        end
    end

endmodule
