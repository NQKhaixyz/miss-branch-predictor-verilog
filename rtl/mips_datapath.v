`timescale 1ns/1ps
`default_nettype none

module mips_decode (
    input  wire [31:0] instruction,
    output reg         legal,
    output reg         use_rs,
    output reg         use_rt,
    output reg         use_immediate,
    output reg         reg_write,
    output reg         mem_read,
    output reg         mem_write,
    output reg         branch_eq,
    output reg         branch_ne,
    output reg  [1:0]  alu_op,
    output reg  [4:0]  destination,
    output wire [31:0] immediate
);
    assign immediate = {{16{instruction[15]}}, instruction[15:0]};

    always @* begin
        legal = 1'b1;
        use_rs = 1'b1;
        use_rt = 1'b0;
        use_immediate = 1'b0;
        reg_write = 1'b0;
        mem_read = 1'b0;
        mem_write = 1'b0;
        branch_eq = 1'b0;
        branch_ne = 1'b0;
        alu_op = 2'd0; // ADD
        destination = instruction[20:16]; // rt for I-type register writes

        case (instruction[31:26])
            6'h00: begin
                use_rt = 1'b1;
                reg_write = 1'b1;
                destination = instruction[15:11];
                case (instruction[5:0])
                    6'h21: alu_op = 2'd0; // addu
                    6'h23: alu_op = 2'd1; // subu
                    6'h2a: alu_op = 2'd2; // slt, signed
                    6'h00: begin         // sll (includes nop)
                        use_rs = 1'b0;
                        alu_op = 2'd3;
                    end
                    default: legal = 1'b0;
                endcase
            end
            6'h09: begin // addiu
                use_immediate = 1'b1;
                reg_write = 1'b1;
            end
            6'h23: begin // lw
                use_immediate = 1'b1;
                reg_write = 1'b1;
                mem_read = 1'b1;
            end
            6'h2b: begin // sw
                use_rt = 1'b1;
                use_immediate = 1'b1;
                mem_write = 1'b1;
            end
            6'h04: begin // beq
                use_rt = 1'b1;
                branch_eq = 1'b1;
            end
            6'h05: begin // bne
                use_rt = 1'b1;
                branch_ne = 1'b1;
            end
            default: legal = 1'b0;
        endcase
    end
endmodule

module mips_alu (
    input  wire [1:0]  op,
    input  wire [31:0] lhs,
    input  wire [31:0] rhs,
    input  wire [4:0]  shift,
    output reg  [31:0] result
);
    always @* begin
        case (op)
            2'd0: result = lhs + rhs;
            2'd1: result = lhs - rhs;
            2'd2: result = ($signed(lhs) < $signed(rhs)) ? 32'd1 : 32'd0;
            2'd3: result = rhs << shift;
            default: result = 32'd0;
        endcase
    end
endmodule

// Both cores use the same architectural register file. The WB bypass in
// the read ports lets ID see a value written by WB on the same rising edge.
module mips_register_file #(
    parameter WRITE_BYPASS = 1
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [4:0]  rs,
    input  wire [4:0]  rt,
    output wire [31:0] rs_value,
    output wire [31:0] rt_value,
    input  wire        write_enable,
    input  wire [4:0]  write_rd,
    input  wire [31:0] write_data
);
    reg [31:0] registers [0:31];
    integer entry;

    assign rs_value = rs == 5'd0 ? 32'd0 :
                      (WRITE_BYPASS && write_enable && write_rd == rs) ? write_data : registers[rs];
    assign rt_value = rt == 5'd0 ? 32'd0 :
                      (WRITE_BYPASS && write_enable && write_rd == rt) ? write_data : registers[rt];

    always @(posedge clk) begin
        if (reset) begin
            for (entry = 0; entry < 32; entry = entry + 1)
                registers[entry] <= 32'd0;
        end else if (write_enable && write_rd != 5'd0) begin
            registers[write_rd] <= write_data;
        end
    end
endmodule

`default_nettype wire
