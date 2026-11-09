# Thiết kế và mô phỏng bộ dự đoán nhánh (Branch Predictor) cho bộ xử lý MIPS bằng Verilog HDL

Đồ án thiết kế bộ dự đoán hướng 2 bit và BTB để chọn PC kế tiếp cho CPU MIPS pipeline 5 tầng. Mô phỏng so sánh bốn chế độ xử lý nhánh trên cùng chương trình. Mỗi lượt đối chiếu kết quả thực thi với trình thông dịch Python. Các chế độ dự đoán còn được kiểm tra theo từng chu kỳ với mô hình tham chiếu BHT/BTB.

## Chạy lại mô phỏng

Cần Python 3.10+ và Icarus Verilog (`iverilog`, `vvp` trên PATH). Cài `matplotlib` để xuất biểu đồ.

```powershell
python -m pip install -r requirements.txt
python run.py
```

Trên Windows, nếu Icarus chưa nằm trên PATH, truyền thư mục chứa hai tệp thực thi.

```powershell
python run.py --iverilog-bin C:\iverilog\bin
```

Dùng `--no-plot` để chạy chỉ với thư viện chuẩn Python. Lệnh sau chạy nhanh một chương trình và đặt kết quả riêng để giữ nguyên kết quả toàn bộ suite.

```powershell
python run.py --case sum_loop --no-sweep --output build/demo
```

## Nội dung dự án

| Đường dẫn | Nội dung |
|---|---|
| [rtl/](rtl/) | Lõi pipeline, lõi single-cycle, datapath dùng chung và BP |
| [tb/](tb/) | Testbench predictor độc lập và testbench CPU, đối chiếu lệnh hoàn tất và ghi RAM |
| [prediction_trace.py](prediction_trace.py) | Đối chiếu dự đoán ở IF, dữ liệu mang tới EX và cập nhật BHT/BTB |
| [programs/](programs/) | Nguồn assembly, bộ sinh ảnh bộ nhớ và trình thông dịch |
| [docs/DESIGN.md](docs/DESIGN.md) | Đặc tả ISA, sơ đồ trạng thái, giao diện predictor và phép đo |
| [docs/DEMO.md](docs/DEMO.md) | Trình tự demo và tín hiệu xem trong GTKWave |
| [docs/Trinh-bay-MIPS-BP.pptx](docs/Trinh-bay-MIPS-BP.pptx) | Slide thuyết trình và ghi chú demo |
| [results/REPORT.md](results/REPORT.md) | Báo cáo thực nghiệm |
| [results/metrics.csv](results/metrics.csv) | Số liệu từng lần chạy, gồm quét kích thước bảng |
| [results/branch_stats.csv](results/branch_stats.csv) | Số lần dự đoán và nguyên nhân sai PC theo từng địa chỉ nhánh |
| [results/performance.png](results/performance.png) | Độ chính xác hướng và tỷ lệ tăng tốc |

```powershell
python programs/generate.py --list
python programs/generate.py --case sum_loop --out build/programs
gtkwave results/waveforms/sum_loop_two_bit.vcd
```

Tập lệnh gồm `addu`, `subu`, `addiu`, `slt`, `sll`, `lw`, `sw`, `beq`, `bne`, với `nop` mã hóa bằng `sll $0,$0,0`. Mô hình đồ án xử lý nhánh không có delay slot và dùng bộ nhớ lý tưởng có độ trễ cố định.
