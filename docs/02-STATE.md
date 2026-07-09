# 02 — Trạng thái hiện tại

> **Cách dùng file này:** cập nhật sau *mỗi* task xong, không để dồn cuối ngày. Khi quay lại làm việc sau khi nghỉ, đọc file này trước tiên. Nếu bạn (hoặc AI assistant) mở lại project sau vài ngày, đây là file duy nhất cần đọc để biết đang đứng ở đâu.

**Cập nhật lần cuối:** _(chưa bắt đầu)_
**Đang làm:** —
**Blocker hiện tại:** —

---

## Bảng tiến độ

Ký hiệu: `[ ]` chưa làm · `[~]` đang làm · `[x]` xong, đạt DoD · `[!]` bị chặn · `[-]` bỏ, có lý do

### Ngày 1 — Video

| | Task | P | DoD đạt chưa | Ghi chú |
|---|---|---|---|---|
| `[ ]` | T1.1 Dựng môi trường GStreamer | P0 | | |
| `[ ]` | T1.2 Sender/receiver `gst-launch` | P0 | | |
| `[ ]` | T1.3 **Receiver C++ + CMake** | P1 ★ | | |
| `[ ]` | T1.4 Đo latency | P1 | | |
| `[ ]` | T1.5 Thí nghiệm `tc netem` | P1 | | |
| `[ ]` | T1.6 README + demo video | P0 | | |

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
- `[ ]` `appsink` khác `autovideosink` chỗ nào, và khi nào cần?
- `[ ]` Caps negotiation là gì, vì sao `udpsrc` phải khai caps thủ công?
- `[ ]` MAVLink heartbeat mất bao lâu thì coi là đứt link, vì sao con số đó?
- `[ ]` Vì sao phải set mode GUIDED trước khi arm?
- `[ ]` Trên Jetson, pipeline này đổi những element nào?

Đánh dấu `[x]` khi tự giải thích được thành lời cho người khác nghe. Chi tiết ở [04-CONCEPTS.md](04-CONCEPTS.md).

---

## Nhật ký

Ghi ngắn: làm gì, hỏng ở đâu, sửa thế nào. Phần "hỏng ở đâu" là phần đáng giá nhất khi phỏng vấn — người ta hỏi *"kể một lỗi khó em từng debug"* thì đây là chỗ lấy câu trả lời.

### _(chưa có)_

```
YYYY-MM-DD HH:MM — <task> — <việc đã làm> — <vấn đề gặp> — <cách xử lý>
```

---

## Số liệu đã đo

Điền dần, đây là thứ đi thẳng lên CV.

| Chỉ số | Giá trị | Đo bằng cách nào |
|---|---|---|
| Latency — default | _chưa đo_ | |
| Latency — tuned | _chưa đo_ | |
| Bitrate | _chưa đo_ | |
| Hành vi ở 2% packet loss | _chưa đo_ | |
| CPU của `x264enc` | _chưa đo_ | |
