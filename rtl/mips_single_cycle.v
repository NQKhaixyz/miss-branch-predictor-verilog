`timescale 1ns/1ps
`default_nettype none

// Functional baseline. Its cycle count is intentionally excluded from the
// branch prediction performance comparison between the pipeline modes.
module mips_single_cycle (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] imem_rdata,
    output wire [31:0] imem_addr,
    input  wire [31:0] dmem_rdata,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire        dmem_we,
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire        retire_reg_we,
    output wire [4:0]  retire_rd,
    output wire [31:0] retire_reg_data,
    output wire        retire_mem_we,
    output wire [31:0] retire_mem_addr,
    output wire [31:0] retire_mem_data
);
    reg [31:0] pc;
    wire legal;
    wire use_immediate;
    wire reg_write;
    wire mem_read;
    wire mem_write;
    wire branch_eq;
    wire branch_ne;
    wire [1:0] alu_op;
    wire [31:0] immediate;
    wire [31:0] rs_value;
    wire [31:0] rt_value;
    wire [31:0] result;
    wire operands_equal = rs_value == rt_value;
    wire taken = legal && ((branch_eq && operands_equal) || (branch_ne && !operands_equal));
    wire [31:0] fallthrough = pc + 32'd4;

    mips_decode decode (
        .instruction(imem_rdata), .legal(legal), .use_rs(), .use_rt(),
        .use_immediate(use_immediate), .reg_write(reg_write),
        .mem_read(mem_read), .mem_write(mem_write),
        .branch_eq(branch_eq), .branch_ne(branch_ne), .alu_op(alu_op),
        .destination(retire_rd), .immediate(immediate)
    );

    mips_register_file #(.WRITE_BYPASS(0)) rf (
        .clk(clk), .reset(reset), .rs(imem_rdata[25:21]), .rt(imem_rdata[20:16]),
        .rs_value(rs_value), .rt_value(rt_value),
        .write_enable(retire_reg_we), .write_rd(retire_rd), .write_data(retire_reg_data)
    );

    mips_alu alu (
        .op(alu_op), .lhs(rs_value),
        .rhs(use_immediate ? immediate : rt_value),
        .shift(imem_rdata[10:6]), .result(result)
    );

    assign imem_addr = pc;
    assign dmem_addr = result;
    assign dmem_wdata = rt_value;
    assign dmem_we = retire_valid && mem_write;
    assign retire_valid = !reset && legal;
    assign retire_pc = pc;
    assign retire_reg_we = retire_valid && reg_write && retire_rd != 5'd0;
    assign retire_reg_data = mem_read ? dmem_rdata : result;
    assign retire_mem_we = dmem_we;
    assign retire_mem_addr = dmem_addr;
    assign retire_mem_data = dmem_wdata;

    always @(posedge clk) begin
        if (reset)
            pc <= 32'd0;
        else
            pc <= taken ? fallthrough + (immediate << 2) : fallthrough;
    end
endmodule

`default_nettype wire
