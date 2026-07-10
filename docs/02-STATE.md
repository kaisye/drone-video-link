# 02 — Trạng thái hiện tại

> **Cách dùng file này:** cập nhật sau *mỗi* task xong, không để dồn cuối ngày. Khi quay lại làm việc sau khi nghỉ, đọc file này trước tiên. Nếu bạn (hoặc AI assistant) mở lại project sau vài ngày, đây là file duy nhất cần đọc để biết đang đứng ở đâu.

**Cập nhật lần cuối:** 2026-07-10, hết T1.5
**Đang làm:** T1.6 — README `video/` + demo
**Blocker hiện tại:** —

**Môi trường:** WSL2 `Ubuntu-22.04` (chú ý: distro mặc định là `docker-desktop`, phải gọi `wsl -d Ubuntu-22.04`). GStreamer 1.20.3, g++ 11.4, cmake 3.22, 16 lõi. `tc netem` cần chạy bằng root (`wsl -d Ubuntu-22.04 -u root`).

---

## Bảng tiến độ

Ký hiệu: `[ ]` chưa làm · `[~]` đang làm · `[x]` xong, đạt DoD · `[!]` bị chặn · `[-]` bỏ, có lý do

### Ngày 1 — Video

| | Task | P | DoD đạt chưa | Ghi chú |
|---|---|---|---|---|
| `[x]` | T1.1 Dựng môi trường GStreamer | P0 | ✔ 13/13 element | netem chỉ chạy được với root |
| `[x]` | T1.2 Sender/receiver `gst-launch` | P0 | ✔ 235 frame, 0 drop, 30.01 fps | |
| `[x]` | T1.3 **Receiver C++ + CMake** | P1 ★ | ✔ build sạch, valgrind sạch | |
| `[x]` | T1.4 Đo latency | P1 | ✔ 2288 ms → 7.8 ms | phát hiện giả định B-frame sai |
| `[x]` | T1.5 Thí nghiệm `tc netem` | P1 | ✔ 3 ảnh + `packet-loss.md` | `discont` không bắt được mất gói |
| `[~]` | T1.6 README + demo video | P0 | | |

### Ngày 2 — MAVLink

| | Task | P | DoD đạt chưa | Ghi chú |
|---|---|---|---|---|
| `[ ]` | T2.1 ArduPilot SITL (timebox 90') | P0 | | fallback: mock_fc.py |
| `[ ]` | T2.2 Heartbeat + watchdog | P0 | | |
| `[ ]` | T2.3 Telemetry parsing + logging | P0 | | |
| `[ ]` | T2.4 Arm / takeoff / land | P1 | | |
| `[ ]` | T2.5 MQTT bridge | P2 | | |
| `[ ]` | T2.6 Sơ đồ + README | P0 | | |

### Vét

| | Task | P | |
|---|---|---|---|
| `[ ]` | Dockerfile cho `video/` | P2 | |
| `[ ]` | Demo FFmpeg vidstab | P2 | |
| `[ ]` | GitHub Actions | P2 | |

---

## Checkpoint hiểu bài

Project chỉ coi là thành công khi bạn tự trả lời được, **không mở tài liệu**:

- `[ ]` Vì sao video dùng UDP mà không dùng TCP?
- `[ ]` RTP thêm gì lên trên UDP, và vì sao cần?
- `[ ]` `rtpjitterbuffer latency` đánh đổi cái gì lấy cái gì?
- `[ ]` `tune=zerolatency` thực chất tắt những gì trong x264?
- `[ ]` `sync=false` ở sink nghĩa là gì?
- `[ ]` Mất 1 gói UDP, vì sao hình vỡ cả giây chứ không phải 1 frame?
- `[ ]` Vì sao "hỏng nửa GOP" là câu trả lời sai, và câu đúng phụ thuộc vào cái gì?
- `[ ]` Ứng dụng làm sao biết đang mất gói? Vì sao `discont`/`CORRUPTED` vô dụng?
- `[ ]` `latency=0` phải trả giá bao nhiêu khi mạng có jitter?
- `[ ]` `appsink` khác `autovideosink` chỗ nào, và khi nào cần?
- `[ ]` Caps negotiation là gì, vì sao `udpsrc` phải khai caps thủ công?
- `[ ]` MAVLink heartbeat mất bao lâu thì coi là đứt link, vì sao con số đó?
- `[ ]` Vì sao phải set mode GUIDED trước khi arm?
- `[ ]` Trên Jetson, pipeline này đổi những element nào?

Đánh dấu `[x]` khi tự giải thích được thành lời cho người khác nghe. Chi tiết ở [04-CONCEPTS.md](04-CONCEPTS.md).

---

## Nhật ký

Ghi ngắn: làm gì, hỏng ở đâu, sửa thế nào. Phần "hỏng ở đâu" là phần đáng giá nhất khi phỏng vấn — người ta hỏi *"kể một lỗi khó em từng debug"* thì đây là chỗ lấy câu trả lời.

```
YYYY-MM-DD HH:MM — <task> — <việc đã làm> — <vấn đề gặp> — <cách xử lý>
```

**2026-07-10 — T1.1** — Cài GStreamer trong WSL. `sudo` đòi mật khẩu, nhưng `wsl -u root` vào thẳng được root không cần password. `tc netem` chỉ hoạt động dưới root — ghi nhớ cho T1.5.

**2026-07-10 — T1.2** — Chạy sender/receiver headless. Không có gì hỏng. 235 frame, 0 drop.

**2026-07-10 — T1.3** — Viết `receiver.cpp`. Hai lỗi:
1. **`discont=1` ngay frame đầu.** Buffer đầu tiên của mọi stream luôn mang cờ `GST_BUFFER_FLAG_DISCONT` — một stream bắt đầu thì đương nhiên không liên tục. Nếu đếm nó thì baseline lúc mạng hoàn hảo là 1 chứ không phải 0, và cả thí nghiệm T1.5 đọc sai. Đã bỏ qua frame đầu.
2. **Valgrind báo `definitely lost: 16,448 bytes`.** Nhìn stack trace thì nó nằm trong glib/rtpmanager, có vẻ vô can — nhưng suy luận từ stack không phải bằng chứng. Chạy lại hai lần: 50 frame → 16448 bytes, 173 frame → 16448 bytes. Không đổi ⇒ rò một lần, không phải rò theo frame. Phần lớn được cấp phát trong `_dl_init`, tức trước cả `main()`.

**2026-07-10 — T1.4** — Đo latency. **Đây là task dạy được nhiều nhất.**
- Tôi đã tin (và đã viết vào docs, vào comment code, vào cả CV) rằng `tune=zerolatency` tắt B-frame. **Sai.** `x264enc` của GStreamer mặc định `bframes=0` — không có B-frame nào để tắt. Kiểm bằng `gst-inspect-1.0 x264enc | grep -A2 '^  bframes'`.
- Thủ phạm thật: `rc-lookahead=40` (tốn đúng 40 frame) và frame-based multithreading (tốn ~1 frame mỗi luồng; 28 frame trên máy 16 lõi). Tách bạch bằng cách ép `threads=1` rồi quét từng nút.
- Suýt dựng một cột số liệu trên hư không: `fakesink` **không có** element-latency vì tracer lấy mẫu ở src pad, mà sink thì không có src pad. Con số tôi tưởng là của fakesink thực ra do regex `element=` khớp nhầm vào `sink-element=`.
- `sync=false` chỉ bớt 15 ms, nhưng chỗ nó hiện ra không phải chỗ nó gây hại: khi sink nghẽn, buffer dồn ứ **trong jitter buffer** (15,5 ms → 0,8 ms). Element báo triệu chứng ≠ element có bệnh.
- Mean bị lệch vì lúc EOS encoder xả hàng nhanh, kéo mean xuống dưới giá trị trạng thái ổn định (1623 vs median 2070). Dùng median.

**2026-07-10 — T1.5** — Thí nghiệm `tc netem`. **Dụng cụ đo sai ba lần trước khi đúng.**
1. **`GST_BUFFER_FLAG_DISCONT` không bắt được mất gói.** Tôi đã viết đúng câu đó vào comment của `receiver.cpp` ở T1.3. Quét từ 0→20% loss: ở 20%, mất 474 gói, ứng dụng vẫn nhận 148/150 frame, `discont=0`, `CORRUPTED=0`. `avdec_h264` che lỗi im lặng. Dụng cụ đúng là property `stats` của `rtpjitterbuffer` → `num-lost`, và nó phải được đối chiếu với `tc -s qdisc` của kernel.
2. **`num-lost` cũng nói dối khi có đảo gói.** Link chỉ mất gói: `tc`=101, `num-lost`=101, khớp tuyệt đối. Thêm jitter: `num-lost`=3640 trong khi 4580 gói vẫn được đẩy và 270/300 frame giải mã được. Nó đếm *lần phát hiện khoảng trống*, không phải *gói mất*.
3. **`x264enc` không bit-reproducible.** So hai lần chạy sạch với nhau ra 300/300 frame khác nhau. `md5sum` hai lần encode cùng input tất định → hai file khác nhau. Phải **đóng băng bitstream ra file rồi phát lại** thì control mới cho 600/600 frame trùng khít từng bit.
- Cái bẫy thứ tư: dùng ảnh tĩnh SMPTE thì **không thấy hình vỡ ở đâu cả**, vì concealment chép khối từ frame trước — mà với ảnh tĩnh khối đó *đúng*. Camera drone không đứng yên. Đổi sang `pattern=pinwheel`.
- Kết quả: **10/10 đợt hỏng kết thúc đúng tại một IDR.** Sai lệch không phai (phẳng 22,6 suốt GOP rồi rơi về 0,3 tại IDR, và 0,0 tại IDR sạch).
- Phát hiện phản trực giác: "mất 1 gói hỏng nửa GOP" **sai**. Keyframe chiếm 15% số gói (to gấp 15× P-frame), nên kỳ vọng theo phân bố gói là 17,6 frame, đo được 24,1. Monte Carlo trên đúng layout gói: mô hình 61% GOP hỏng / 20,1 frame, đo được 55% / 24,1 frame.
- Và cái giá của `latency=0` (chọn ở T1.4): jitter ±5 ms, **mất 0 gói** → chỉ giải mã được 67/300 frame. `latency=200` → 270–300/300.

---

## Số liệu đã đo

Điền dần, đây là thứ đi thẳng lên CV.

| Chỉ số | Giá trị | Đo bằng cách nào |
|---|---|---|
| Latency — default | **2288 ms** (median) | `GST_TRACERS="latency(flags=pipeline+element)"` |
| Latency — tuned | **7.8 ms** (median) | như trên, `scripts/measure-latency.sh` |
| — trong đó x264enc | 2067 ms → 4.2 ms | element-latency của `x264enc0` |
| — trong đó jitter buffer | 218 ms → 0.8 ms | element-latency của `rtpjitterbuffer0` |
| Chi phí `rc-lookahead=40` | 39.4 frame | ép `threads=1`, quét lookahead |
| Chi phí frame threading | ~1 frame/luồng (28 frame ở 16 lõi) | ép `rc-lookahead=0`, quét threads |
| Kích thước frame I420 | 1 382 400 B = 1280×720×1.5 | `receiver.cpp`, `gst_buffer_map` |
| Rò bộ nhớ theo frame | **0** (16 448 B hằng số, cấp phát trước `main`) | valgrind ở 50 và 173 frame |
| Slice mỗi picture | **11** (do sliced threads) | `scripts/gop-stats.sh` |
| Khoảng cách IDR | đúng 30 picture (min=max) | như trên, quét NAL Annex-B |
| Tỉ lệ I/P | 2,8× (smpte) · 3,2× (ball) · **15,0×** (pinwheel) | như trên |
| Gói thuộc keyframe | **15%** tổng số gói | như trên, mô hình FU-A mtu=1400 |
| Đợt hỏng kết thúc tại IDR | **10/10** | `scripts/frame-diff.sh`, bitstream đóng băng |
| Thiệt hại mỗi GOP bị trúng | **24,1 picture ≈ 803 ms** (mô hình: 20,1) | như trên |
| Cờ `discont`/`CORRUPTED` ở 20% loss | **0 / 0** (decoder che lỗi im lặng) | quét loss 0→20% |
| `latency=0`, jitter ±5 ms, **0 gói mất** | chỉ **67/300** picture | control `netem delay 20ms 5ms` |
| `latency=200`, cùng điều kiện | **270–300/300** picture | 3 lần chạy |
| `wait-for-keyframe` ở 2% loss | **11/300** picture được hiển thị | `receiver --wait-for-keyframe` |
