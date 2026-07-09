# 00 — Tổng quan

## 1. Bài toán thật ngoài đời

Một chiếc drone trinh sát / quay phim có ba khối phần cứng liên quan đến project này:

- **Flight Controller (FC)** — thường là Pixhawk, chạy ArduPilot hoặc PX4. Nó điều khiển động cơ, đọc IMU/GPS, giữ thăng bằng. Nó **không** xử lý video.
- **Companion computer** — Jetson Orin NX hoặc chip Qualcomm. Cắm camera vào, chạy Linux, làm ba việc: encode video, đẩy video xuống mặt đất, và nói chuyện với FC qua UART.
- **Ground station** — laptop của người điều khiển. Nhận video, hiển thị, gửi lệnh lên drone.

Giữa companion computer và ground station có **một đường truyền duy nhất** (radio link, hoặc Ethernet khi test trên bàn). Trên đường truyền đó có **hai luồng dữ liệu chạy song song**:

1. **Video downlink** — một chiều, băng thông lớn (vài Mbps), yêu cầu **độ trễ thấp**. Người lái nhìn màn hình để bay; trễ 500ms là đâm cây.
2. **MAVLink** — hai chiều, băng thông nhỏ (vài KB/s), yêu cầu **tin cậy**. Telemetry đi xuống (độ cao, GPS, pin), lệnh đi lên (arm, takeoff, land).

JD của công ty mô tả đúng ba việc: làm pipeline video trên Jetson, truyền video qua Ethernet với độ trễ thấp, và tích hợp MAVLink để điều khiển drone.

## 2. Project này mô phỏng cái gì

Không có drone, không có Jetson, không có camera. Ta thay thế **phần cứng**, giữ nguyên **phần mềm**:

| Ngoài đời | Trong project | Ghi chú |
|---|---|---|
| Camera CSI/USB | `videotestsrc` | Cùng là một GStreamer source. Đổi 1 dòng là ra camera thật. |
| Hardware encoder `nvv4l2h264enc` | `x264enc` (software) | Cùng xuất ra H.264. Latency khác, cách dùng giống. |
| Radio link / Ethernet | `127.0.0.1` loopback | Dùng `tc netem` để giả lập mất gói, jitter. |
| Pixhawk chạy ArduPilot | ArduPilot **SITL** | SITL là chính firmware ArduPilot compile cho PC. Protocol y hệt. |
| UART giữa FC và companion | UDP port 14550 | MAVLink không quan tâm nó chạy trên transport nào. |

## 3. Vậy cái gì là "thật" trong project này?

Đây là câu hỏi quan trọng nhất, vì nó quyết định project có giá trị hay không.

**Thật 100%:**
- GStreamer pipeline, element, caps negotiation, `appsink`
- RTP payload/depayload, jitter buffer
- H.264 GOP structure, keyframe, ảnh hưởng của mất gói
- MAVLink message parsing, heartbeat, command protocol
- Code C++ dùng GStreamer C API, build bằng CMake
- Kỹ thuật đo latency, `GST_TRACERS`, `tc netem`

**Giả lập (nhưng thay được bằng 1 dòng):**
- Nguồn video
- Encoder phần cứng
- Đường truyền vật lý

**Không đụng tới:**
- Yocto / Buildroot / U-Boot / Device Tree
- Chống rung ảnh (image stabilization) — chỉ có một demo FFmpeg `vidstab` nhỏ, không tự viết thuật toán
- Gimbal control, camera control (MAVLink camera protocol)
- Bảo mật link (không encrypt)

Việc ghi rõ ranh giới này trong README **là điểm cộng**, không phải điểm trừ. Người phỏng vấn ghét nhất là ứng viên nói quá về project của mình.

## 4. Tiêu chí thành công

Project coi là xong khi trả lời được ba câu, **có số liệu kèm theo**:

1. **Latency của pipeline là bao nhiêu ms, và tôi giảm nó bằng cách nào?**
   → Bảng so sánh default vs tuned, đo bằng `GST_TRACERS=latency`.

2. **Khi mạng mất 2% gói thì video hỏng thế nào, và vì sao?**
   → Screenshot vỡ hình + giải thích qua GOP/keyframe.

3. **Tôi có viết được ứng dụng GStreamer bằng C++ không, hay chỉ chạy `gst-launch`?**
   → `video/src/receiver.cpp` + `CMakeLists.txt`.

Cộng thêm, cho phần MAVLink:

4. **Tôi có hiểu MAVLink là protocol chứ không phải thư viện không?**
   → Gateway tự parse heartbeat, tự gửi `MAV_CMD_NAV_TAKEOFF`, có watchdog khi mất heartbeat.

## 5. Nguyên tắc xuyên suốt

> Không viết một dòng code nào mà không giải thích được vì sao nó ở đó.

Nếu bạn copy một pipeline từ StackOverflow và nó chạy, **dừng lại**, mở [04-CONCEPTS.md](04-CONCEPTS.md), tra từng element một. Mục tiêu của project không phải là làm nó chạy — mà là hiểu vì sao nó chạy.
