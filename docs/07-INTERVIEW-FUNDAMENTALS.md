# 07 — Câu hỏi phỏng vấn: nền tảng & diện rộng

> File [06-INTERVIEW-QA.md](06-INTERVIEW-QA.md) đã phủ **sâu** phần video + MAVLink của chính dự án này. File này phủ phần **còn lại** mà một buổi phỏng vấn Embedded ở Gremsy chắc chắn chạm tới: giới thiệu bản thân, C/C++ nền tảng, RTOS, dự án AGV (EKF/PID), STM32 bare-metal, CAN/Bosch, câu hành vi, và câu hỏi ngược lại.
>
> **Cách dùng:** đọc to thành lời, không nhìn giấy. Câu nào ấp úng thì đánh dấu và quay lại tra. Con số nào có trong dự án đều là **số đo thật** — đừng làm tròn thành số mơ hồ, vì sự cụ thể chính là thứ tách bạn khỏi ứng viên copy tutorial.
>
> Ký hiệu **★** = câu hay bị vặn sâu, phải chắc.

---

## Nhóm 0 — Giới thiệu bản thân & về Gremsy

Đây là 3 phút đầu quyết định cả buổi. Phải thuộc như phản xạ.

**Q: Em giới thiệu bản thân đi. (bản 30 giây)**
> Em là kỹ sư embedded, hơn 1 năm làm firmware C/C++ và **CAN** cho ECU ô tô tại Bosch. Trước đó em dẫn một nhóm 2 người làm robot giao hàng tự hành ngoài trời — em viết firmware điều khiển từ đọc cảm biến tới actuator, làm **EKF sensor fusion** trên IMU/encoder/GNSS và **điều khiển động cơ PID**. Gần đây em tự làm một dự án low-latency **video downlink GStreamer/RTP + MAVLink** trên Embedded Linux để chuẩn bị đúng cho vị trí này ở Gremsy.

**Q: Em kể chi tiết hơn về bản thân đi. (bản 2 phút)**
> Hai mạch trong hồ sơ của em hội tụ về control-firmware cho gimbal-trên-drone, nên em đặc biệt muốn làm ở Gremsy.
>
> Mạch thứ nhất là **embedded thật, phần cứng thật**: ở Bosch em làm CAN cho ECU — phân tích signal/frame/bus, tái hiện và trace lỗi trên target bằng logic analyzer và oscilloscope. Trước đó ở đồ án AGV, em làm firmware bare-metal end-to-end trên STM32, tự implement EKF để giữ pose ổn định khi GPS nhiễu hoặc mất tín hiệu, và PID điều khiển động cơ có phản hồi encoder — tức là em đã tự tay làm đúng vòng cảm biến-ước lượng-điều khiển mà một gimbal cũng chạy.
>
> Mạch thứ hai là dự án gần nhất: em xây một video downlink H.264 qua RTP/UDP, viết receiver bằng C++ trên GStreamer C API, và một MAVLink gateway kiểm chứng với ArduPilot SITL. Điểm em tự hào nhất không phải là code chạy, mà là em đo mọi thứ và đối chiếu bằng dụng cụ độc lập — em cắt latency pipeline từ 2288 ms xuống 7.8 ms và biết chính xác từng ms đến từ đâu.

**Q: ★ Em biết gì về Gremsy, và vì sao là Gremsy?**
> Gremsy là công ty Việt Nam làm **hệ thống gimbal ổn định hình chuyên nghiệp** cho drone và quay phim điện ảnh, xuất khẩu đi thị trường quốc tế. Cốt lõi kỹ thuật của gimbal là đúng thứ em đã làm ở đồ án AGV: đọc **IMU** tần số cao, **ước lượng tư thế** (attitude estimation, họ hàng với EKF em đã viết), rồi **điều khiển vòng kín 3 motor** để triệt rung — cộng thêm tích hợp với flight controller qua **MAVLink/giao thức gimbal**. Em thích Gremsy vì đây là một trong số ít chỗ ở Việt Nam mà hai mảng em mạnh nhất — control firmware thời gian thực và kỹ thuật video/truyền dẫn độ trễ thấp — gặp nhau trong cùng một sản phẩm.

**Q: Điểm mạnh lớn nhất của em?**
> Kỷ luật đo lường. Em không tin một con số cho tới khi đối chiếu được nó bằng một dụng cụ thứ hai độc lập. Trong dự án vừa rồi thói quen đó cứu em ba lần khỏi báo cáo số sai mà vẫn thấy hợp lý — ví dụ một bộ đếm mất gói báo 3640 trên một link chỉ thật sự mất 90 gói.

**Q: Điểm yếu lớn nhất?**
> Em từng có xu hướng đào một vấn đề sâu hơn mức cần thiết cho deadline. Em đang sửa bằng cách chốt trước "kết quả tối thiểu đủ tốt" cho từng phần rồi mới bắt đầu, và chỉ đào sâu phần nào thật sự đáng. Trong dự án này em áp dụng đúng vậy: em bỏ hẳn Yocto vì tỉ lệ giá-trị/thời-gian của nó tệ nhất, để dồn giờ cho video và MAVLink là phần lõi.

---

## Nhóm A — C / C++ nền tảng cho embedded

Đây là phần "sát hạch" gần như chắc chắn có. Trả lời gọn, đúng, có ví dụ.

**Q: `volatile` để làm gì? Khi nào bắt buộc dùng?**
> `volatile` bảo compiler **không được tối ưu bỏ hoặc cache** việc đọc/ghi biến, vì giá trị có thể thay đổi ngoài luồng lệnh hiện tại. Ba chỗ bắt buộc trong embedded: (1) **thanh ghi phần cứng** memory-mapped — đọc hai lần phải ra hai lần đọc thật; (2) biến **chia sẻ với ISR** — main loop phải đọc lại giá trị mới ISR vừa ghi; (3) biến chia sẻ giữa các luồng (dù ở đó nên dùng atomic/rào cản đúng nghĩa). Lưu ý: `volatile` **không** đảm bảo atomic và **không** đảm bảo thứ tự bộ nhớ giữa nhiều core — nó chỉ chống tối ưu hoá, không phải công cụ đồng bộ.

**Q: `volatile` khác `atomic` thế nào?**
> `volatile` = "đừng tối ưu việc truy cập này". `atomic` = "việc truy cập này không bị chen ngang và có ràng buộc thứ tự bộ nhớ". Trên MCU single-core, đọc/ghi một biến chia sẻ với ISR: `volatile` là đủ nếu truy cập vốn atomic ở mức phần cứng (ví dụ đọc 1 biến 32-bit trên Cortex-M32). Nếu là biến 64-bit hay chuỗi thao tác read-modify-write thì phải chặn ngắt (critical section) hoặc dùng atomic thật.

**Q: `const` với con trỏ — phân biệt các dạng.**
> `const int* p` — trỏ tới int hằng, đổi `*p` không được, đổi `p` được. `int* const p` — con trỏ hằng, đổi `p` không được, đổi `*p` được. `const int* const p` — cả hai đều không đổi được. Mẹo đọc: đọc từ phải qua trái quanh biến. Trong embedded, đặt bảng tra (lookup table) là `const` để linker để nó vào **flash/ROM** thay vì tốn RAM.

**Q: `static` có mấy nghĩa?**
> Ba: (1) biến local `static` — tồn tại suốt vòng đời chương trình, giữ giá trị giữa các lần gọi hàm, khởi tạo một lần; (2) biến/hàm global `static` — giới hạn **liên kết nội bộ** trong một file (.c), tránh đụng tên; (3) thành viên `static` của class C++ — dùng chung cho mọi instance. Trong embedded, `static` cấp phát tĩnh giúp biết trước dung lượng RAM, tránh phân mảnh heap.

**Q: ★ Stack và heap khác nhau, và vì sao embedded ngại dùng heap?**
> Stack cấp phát/giải phóng theo LIFO tự động theo scope, rất nhanh, nhưng dung lượng nhỏ và cố định. Heap cấp phát động lúc chạy (`malloc`/`new`), linh hoạt nhưng: (1) **phân mảnh** — sau nhiều lần cấp/giải phóng, còn tổng bộ nhớ nhưng không còn khối liền đủ lớn, `malloc` fail không đoán trước được; (2) thời gian cấp phát **không tất định**, hỏng ràng buộc real-time; (3) rủi ro leak tích luỹ tới OOM. Nên hệ embedded an toàn thường cấp phát tĩnh hoặc dùng memory pool cỡ cố định. Chuẩn như MISRA C khuyến cáo tránh cấp phát động sau khởi tạo.

**Q: Con trỏ với tham chiếu (reference) khác gì trong C++?**
> Reference phải được gán khi khai báo và không đổi đối tượng nó tham chiếu, không thể null; con trỏ có thể null, có thể trỏ lại chỗ khác, làm số học con trỏ. Dùng reference khi chắc chắn có đối tượng và không đổi; dùng con trỏ khi cần "không có gì" (null) hoặc cần đổi mục tiêu.

**Q: `#define` và `const`/`constexpr` — chọn cái nào?**
> `const`/`constexpr` có **kiểu**, được compiler kiểm tra, debug thấy được, không dính bẫy thay-thế-văn-bản. `#define` chỉ nên dùng cho include-guard, biên dịch điều kiện, hoặc macro thật sự cần. Ví dụ bẫy kinh điển: `#define SQ(x) x*x` rồi `SQ(a+b)` nở thành `a+b*a+b`. Ưu tiên `constexpr`.

**Q: Endianness là gì, khi nào bạn phải quan tâm?**
> Thứ tự byte của một số nhiều byte trong bộ nhớ: little-endian để byte thấp trước (ARM, x86), big-endian ngược lại. Phải quan tâm khi **dữ liệu qua ranh giới**: giao thức mạng (network byte order là big-endian), đọc/ghi file nhị phân, giao tiếp giữa hai chip khác endian. MAVLink chẳng hạn định nghĩa rõ little-endian trên đường truyền nên phải đổi đúng khi parse. Đừng bao giờ ép kiểu con trỏ struct lên buffer thô rồi giả định layout — vừa dính endian vừa dính padding.

**Q: Struct padding / alignment là gì?**
> Compiler chèn byte đệm để mỗi trường nằm ở địa chỉ chia hết cho kích thước của nó, vì truy cập lệch (misaligned) chậm hoặc lỗi trên một số kiến trúc. Hệ quả: `sizeof(struct)` lớn hơn tổng các trường, và **không được** giả định layout khi truyền struct qua mạng/lưu file. Muốn layout chặt thì `#pragma pack` hoặc serialize từng trường tường minh — nhưng packed lại có thể gây truy cập lệch, phải cân nhắc.

**Q: Bitwise — set/clear/toggle/test một bit thứ n?**
> Set: `reg |= (1u << n);` Clear: `reg &= ~(1u << n);` Toggle: `reg ^= (1u << n);` Test: `if (reg & (1u << n))`. Đây là ngôn ngữ hằng ngày của thao tác thanh ghi ngoại vi. Nhớ dùng hằng `unsigned` (`1u`) để tránh undefined behavior khi dịch bit.

**Q: Nguyên tắc viết ISR (hàm phục vụ ngắt)?**
> (1) **Ngắn nhất có thể** — chỉ set cờ / đẩy dữ liệu vào queue, xử lý nặng để cho main loop hoặc task; (2) **không** gọi hàm blocking, `printf`, `malloc` trong ISR; (3) biến chia sẻ với main phải `volatile` và bảo vệ nếu là read-modify-write; (4) xoá cờ ngắt đúng cách để không bị gọi lại vô hạn; (5) cẩn thận **priority/nesting** để tránh chặn ngắt quan trọng hơn. Mẫu chuẩn: ISR → set flag hoặc `xQueueSendFromISR` → task xử lý.

**Q: `inline`, và vì sao đôi khi không nên?**
> `inline` gợi ý compiler chèn thẳng thân hàm để bỏ chi phí gọi hàm — hợp với hàm nhỏ gọi nhiều. Nhược: **phình code size** (quan trọng khi flash hạn hẹp), và chỉ là gợi ý, compiler có quyền phớt. Trên MCU flash nhỏ, đánh đổi tốc-độ-đổi-lấy-dung-lượng phải cân.

---

## Nhóm B — RTOS & real-time

CV có FreeRTOS, và Gremsy chạy firmware thời gian thực. Phải chắc phần này.

**Q: RTOS khác vòng lặp superloop (bare-metal) ở đâu? Khi nào cần RTOS?**
> Superloop chạy tuần tự trong `while(1)`, đơn giản, tất định, đủ cho việc nhỏ. RTOS cho phép nhiều **task** với **ưu tiên** và một **scheduler** chia CPU, nên một việc gấp có thể chen trước việc chậm. Cần RTOS khi có nhiều hoạt động đồng thời với ràng buộc thời gian khác nhau (ví dụ vòng điều khiển 1 kHz + xử lý truyền thông + logging), khó lồng ghép thủ công trong một superloop. Đánh đổi: thêm phức tạp, tốn RAM cho stack mỗi task, và rủi ro đồng bộ.

**Q: "Real-time" nghĩa là gì? Hard vs soft?**
> Real-time = **đúng hạn**, không phải **nhanh**. Đúng đắn phụ thuộc cả kết quả lẫn thời điểm cho ra kết quả. Hard real-time: trễ hạn = hỏng hệ thống (điều khiển bay, ABS). Soft real-time: trễ hạn làm giảm chất lượng nhưng không thảm hoạ (streaming). Vòng ổn định gimbal nghiêng về hard — trễ một chu kỳ là rung hiện lên hình.

**Q: Mutex khác semaphore?**
> Mutex bảo vệ **vùng tài nguyên dùng chung**, có khái niệm **chủ sở hữu** (ai lock thì người đó unlock) và thường có **priority inheritance** để chống đảo ưu tiên. Semaphore là bộ đếm để **báo hiệu/đồng bộ** giữa task-task hoặc ISR-task (ví dụ ISR `give`, task `take`), không có chủ sở hữu. Quy tắc thô: bảo vệ dữ liệu → mutex; báo hiệu sự kiện → semaphore.

**Q: ★ Priority inversion là gì, khắc phục sao?**
> Task ưu tiên cao chờ một mutex đang bị task ưu tiên thấp giữ; giữa chừng một task ưu tiên trung bình chen vào chạy, làm task thấp không kịp nhả mutex — task cao bị chặn bởi task trung, đảo ngược ưu tiên. Đây là lỗi từng suýt làm hỏng Mars Pathfinder. Khắc phục: **priority inheritance** (task thấp tạm được nâng lên ưu tiên của task cao đang chờ nó) hoặc **priority ceiling**. FreeRTOS mutex có priority inheritance; semaphore đếm thì không — đó là một lý do chọn mutex để bảo vệ tài nguyên.

**Q: Deadlock hình thành thế nào, tránh ra sao?**
> Bốn điều kiện Coffman cùng lúc: loại trừ tương hỗ, giữ-và-chờ, không tước đoạt, chờ vòng tròn. Cách tránh thực dụng nhất là **luôn lấy nhiều lock theo cùng một thứ tự toàn cục**, dùng timeout khi lấy lock, và giữ vùng critical ngắn.

**Q: Vì sao trong ISR phải dùng biến thể `...FromISR`?**
> Vì API thường có thể blocking hoặc gọi scheduler; trong ngữ cảnh ISR điều đó nguy hiểm. `xQueueSendFromISR`/`xSemaphoreGiveFromISR` không block và trả về cờ báo có cần yield ngay khi thoát ISR không (`portYIELD_FROM_ISR`) để task ưu tiên cao vừa được đánh thức chạy tức thì.

**Q: Watchdog timer để làm gì?**
> Một bộ đếm phần cứng sẽ **reset MCU** nếu phần mềm không "vỗ" (kick/feed) nó trong hạn. Nó bắt các treo do deadlock, vòng lặp vô hạn, hỏng trạng thái. Nguyên tắc: chỉ feed watchdog ở nơi chứng minh hệ thống còn khoẻ thật sự (ví dụ sau khi các task chính đều báo sống), không feed bừa trong một timer vô điều kiện — làm vậy watchdog thành vô dụng. (Ý tưởng "heartbeat watchdog 3 giây" trong MAVLink gateway của dự án là đúng họ khái niệm này ở tầng giao thức.)

---

## Nhóm C — Đồ án AGV: EKF, sensor fusion, PID

Đây là mục lớn nhất trên CV chưa có Q&A. Interviewer control chắc chắn đào. Bạn là **Team Leader (2 người)** và làm firmware end-to-end.

**Q: Kalman filter là gì, giải thích như cho người mới?**
> Là bộ ước lượng đệ quy hợp nhất hai nguồn không chắc chắn: một **mô hình dự đoán** ("dựa vận tốc, giây tới xe ở đâu") và một **phép đo có nhiễu** (GPS/encoder). Nó giữ cả ước lượng trạng thái lẫn **độ bất định** của ước lượng đó, và ở mỗi bước trộn dự đoán với đo theo tỉ lệ nghịch với độ tin cậy tương đối của mỗi bên. Kết quả mượt và chính xác hơn dùng riêng bất kỳ nguồn nào.

**Q: Chu trình predict / update?**
> **Predict:** dùng mô hình chuyển động đẩy trạng thái tới bước kế và **tăng** hiệp phương sai (bất định lớn lên vì chỉ đoán). **Update:** khi có phép đo, tính **Kalman gain** — trọng số quyết định tin đo hay tin dự đoán — rồi kéo trạng thái về phía phép đo theo gain đó và **giảm** hiệp phương sai. Gain cao khi đo đáng tin (nhiễu đo nhỏ), gain thấp khi đo nhiễu.

**Q: Vì sao **Extended** Kalman filter chứ không Kalman thường?**
> KF chuẩn giả định hệ **tuyến tính**. Chuyển động xe/robot không tuyến tính — heading vào qua sin/cos, quay vòng là phi tuyến. EKF **tuyến tính hoá quanh điểm hiện tại** bằng đạo hàm Jacobian ở mỗi bước rồi áp công thức KF. Đó là lý do bài toán pose (x, y, heading) cần EKF.

**Q: Em fuse những cảm biến nào, mỗi cái bù khuyết điểm gì?**
> **IMU** (gia tốc + con quay) cho cập nhật nhanh, tần số cao, nhưng tích phân ra vận tốc/vị trí thì **trôi (drift)** tích luỹ. **Encoder** bánh xe cho quãng đường tương đối chính xác nhưng bị **trượt bánh** và không biết vị trí tuyệt đối. **GNSS** cho vị trí **tuyệt đối** nhưng nhiễu, tần số thấp, và **mất tín hiệu** dưới tán cây/nhà. EKF fuse để: IMU/encoder giữ pose mượt và liên tục giữa các lần GPS về, GPS neo lại để chống trôi dài hạn. Khi GPS dropout, filter vẫn chạy bằng dead-reckoning từ IMU/encoder, bất định nở dần cho tới khi GPS về.

**Q: ★ GPS mất tín hiệu thì hệ của em xử lý sao?**
> EKF vẫn **predict** bình thường bằng IMU + encoder, chỉ là không có bước **update** từ GPS, nên hiệp phương sai (độ bất định) **nở dần** — hệ thống tự biết là nó đang kém chắc chắn hơn. Khi GPS về, một update sẽ kéo pose về và co bất định lại. Điểm hay của cách này so với "chỉ dùng GPS" là robot không nhảy giật hay đứng khựng khi mất fix — nó trôi mượt một cách có kiểm soát và tự định lượng được sai số.

**Q: PID là gì, mỗi hạng tử làm gì?**
> Bộ điều khiển kéo giá trị đo về setpoint dựa trên sai số `e`. **P** (tỉ lệ) phản ứng theo sai số hiện tại — tăng P đáp ứng nhanh hơn nhưng quá tay thì dao động. **I** (tích phân) cộng dồn sai số quá khứ để **triệt sai số tĩnh** (steady-state error) — cái mà P một mình không khử hết. **D** (vi phân) phản ứng theo tốc độ đổi của sai số, **giảm vọt lố và dao động** như một cái phanh. Trong dự án em dùng nó cho vòng tốc độ động cơ có phản hồi encoder.

**Q: Em tune PID thế nào?**
> Em làm thực nghiệm có kỷ luật: tăng P tới khi bắt đầu dao động rồi lùi lại, thêm I để khử sai số tĩnh, thêm D vừa đủ để dập vọt lố mà không khuếch đại nhiễu (D rất nhạy nhiễu đo). Em quan sát đáp ứng bước (step response): rise time, overshoot, settling time, steady-state error. Có thể nhắc Ziegler–Nichols như điểm khởi đầu, nhưng thực tế em tinh chỉnh theo hành vi đo được vì mô hình động cơ + tải không lý tưởng.

**Q: Bẫy hay gặp của khâu I?**
> **Integral windup**: khi actuator bão hoà (đã full ga mà chưa tới setpoint), hạng tử I vẫn cộng dồn to dần, tới lúc quay đầu thì nó "quán tính" gây vọt lố lớn và trễ. Khắc phục: **anti-windup** — kẹp (clamp) giá trị tích phân hoặc ngừng tích phân khi output bão hoà.

**Q: Vòng điều khiển của em chạy tần số bao nhiêu, vì sao quan trọng?**
> Vòng điều khiển phải chạy **đều đặn, tất định** (ví dụ trên một timer ngắt), vì cả PID lẫn EKF đều giả định `dt` biết trước và ổn định. Nếu chu kỳ giật (jitter timing), đạo hàm D và tích phân I sai, chất lượng điều khiển giảm. Đây là lý do vòng điều khiển nên nằm trong ISR timer hoặc task ưu tiên cao chu kỳ cố định, tách khỏi việc chậm như logging.

---

## Nhóm D — Bare-metal STM32

CV: thang máy 3 tầng (FSM), báo cháy (I2C + LCD + UART). Đây là phần "biết chạm sắt".

**Q: Vì sao dùng FSM (máy trạng thái) cho bộ điều khiển thang máy?**
> Vì hành vi phụ thuộc **trạng thái hiện tại + sự kiện**, không chỉ input tức thời. FSM làm logic **tường minh và kiểm chứng được**: các trạng thái như IDLE / MOVING_UP / MOVING_DOWN / DOOR_OPEN, mỗi sự kiện (nhấn nút, tới tầng, hết timer) gây chuyển trạng thái xác định. Thay vì rừng `if` lồng nhau dễ sót ca, FSM liệt kê hết chuyển tiếp hợp lệ nên dễ chứng minh không có trạng thái kẹt hay hành vi bất ngờ.

**Q: ★ Polling vs interrupt — khi nào dùng cái nào?**
> Polling: chủ động hỏi liên tục, đơn giản, tất định, nhưng đốt CPU và có thể **bỏ lỡ** sự kiện ngắn giữa hai lần hỏi. Interrupt: phần cứng báo khi có sự kiện, CPU rảnh làm việc khác, phản ứng độ trễ thấp, nhưng phức tạp hơn (đồng bộ, tái nhập). Quy tắc: sự kiện **hiếm/gấp/ngắn** (nút nhấn, gói UART tới, cạnh tín hiệu) → interrupt; thăm dò **đều và thường xuyên** một trạng thái không gấp → polling. Trong báo cháy, cảm biến chạm ngưỡng dùng interrupt để cảnh báo tức thì.

**Q: Chống dội phím (debounce) là gì, làm sao?**
> Nút cơ khi nhấn tạo nhiều cạnh nhiễu trong vài ms, một lần nhấn bị đọc thành nhiều lần. Debounce: sau cạnh đầu, **bỏ qua** thay đổi trong ~20–50 ms, bằng phần mềm (timer/đếm mẫu ổn định) hoặc phần cứng (RC + Schmitt trigger). Trong ISR nút nhấn, mẫu chuẩn là set cờ + khởi động timer, xác nhận ở lần kiểm sau.

**Q: PWM sinh ra sao và dùng làm gì?**
> Timer đếm tới giá trị chu kỳ (period) và so với giá trị compare; tỉ lệ thời gian mức cao = **duty cycle**. Đổi duty đổi công suất trung bình. Dùng để chỉnh độ sáng LED, tốc độ/chiều động cơ (qua driver), điều khiển servo (độ rộng xung), hoặc tổng hợp tín hiệu analog thô. Với động cơ, tần số PWM phải đủ cao để êm và ngoài dải nghe.

**Q: I2C với SPI với UART — so sánh nhanh.**
> **UART**: bất đồng bộ, 2 dây (TX/RX), không clock chung, hai bên phải khớp baud, điểm-điểm. **I2C**: đồng bộ, 2 dây (SDA/SCL) dùng chung cho **nhiều thiết bị** định địa chỉ, tốc độ vừa, có ACK/NACK, cần điện trở kéo lên. **SPI**: đồng bộ, 4 dây (MOSI/MISO/SCLK/CS), **nhanh nhất**, full-duplex, mỗi slave một chân CS nên tốn chân khi nhiều thiết bị. Chọn: cảm biến chậm nhiều-thiết-bị-ít-dây → I2C; tốc độ cao (ADC, màn hình, flash) → SPI; log/giao tiếp module → UART.

**Q: Cảm biến báo cháy của em, luồng dữ liệu ra sao?**
> Cảm biến nhiệt độ qua **I2C** → so ngưỡng → nếu vượt thì cảnh báo **interrupt-driven** (còi/LED) và ghi **UART** log ra ngoài, đồng thời hiện trạng thái lên **LCD**. Em kiểm chứng bằng input cảm biến thật trên phần cứng, không chỉ mô phỏng.

**Q: HAL vs lập trình thanh ghi trực tiếp (register/bare-metal)?**
> HAL (như STM32 HAL) nhanh để dựng, portable giữa dòng chip, nhưng nặng và che mất chi tiết. Viết thẳng thanh ghi cho code nhỏ, nhanh, kiểm soát tuyệt đối, và **hiểu đúng phần cứng** — nhưng lâu và dễ sai. Em đã làm cả hai; giá trị của bare-metal là khi debug, em đọc được datasheet và biết chính xác bit nào trong thanh ghi nào đang làm gì.

---

## Nhóm E — CAN & kinh nghiệm Bosch

CV: hơn 1 năm CAN cho ECU ô tô, logic analyzer + oscilloscope. Bosch là công ty ô tô nên CAN gần như chắc chắn bị hỏi.

**Q: CAN bus là gì, vì sao ô tô dùng nó?**
> Bus nối tiếp **đa chủ (multi-master)**, phát-quảng-bá theo **bản tin định danh bằng ID** (không theo địa chỉ node), differential hai dây (CAN_H/CAN_L) nên **chống nhiễu tốt** — quan trọng trong môi trường điện ồn của xe. Node nào cũng nghe mọi frame và tự lọc theo ID. Nó thay bó dây điểm-điểm khổng lồ bằng một bus chung, và có cơ chế phát hiện lỗi mạnh.

**Q: ★ Arbitration (phân xử) trên CAN hoạt động sao?**
> Khi nhiều node phát cùng lúc, chúng phân xử **không phá huỷ (non-destructive)** theo từng bit của ID: bit '0' (dominant) đè bit '1' (recessive). Node nào phát recessive mà đọc thấy dominant trên bus thì biết mình thua, **im lặng rút lui** và thử lại sau; node thắng cứ thế phát tiếp không mất dữ liệu. Hệ quả: **ID nhỏ hơn = ưu tiên cao hơn**, và bản tin ưu tiên cao không bị trễ vì tranh chấp. Đây là cơ chế đẹp nhất của CAN.

**Q: CAN phát hiện lỗi bằng cách nào?**
> Năm cơ chế chồng nhau: **CRC**, **ACK slot** (node nhận kéo dominant xác nhận), **form check** (kiểm các bit cố định của khung), **bit monitoring** (bên phát tự đọc lại bus so với bit mình gửi), và **bit stuffing** (sau 5 bit cùng mức chèn 1 bit ngược để giữ đồng bộ clock; sai luật stuffing = lỗi). Node còn có bộ đếm lỗi TEC/REC và chuyển trạng thái error-active → error-passive → **bus-off** để tự cô lập node hỏng.

**Q: CAN với CAN-FD khác gì?**
> CAN-FD (Flexible Data-rate) cho **payload tới 64 byte** thay vì 8, và **tăng tốc độ** ở phần dữ liệu (sau arbitration chuyển sang bitrate cao hơn). Dùng khi cần thông lượng lớn hơn mà giữ hạ tầng CAN. Arbitration vẫn theo cùng nguyên tắc.

**Q: Em debug lỗi CAN trên phần cứng thế nào?**
> Em tái hiện lỗi trên **target thật**, rồi dùng **logic analyzer** để giải mã frame ở tầng số (ID, DLC, data, CRC, ACK) và **oscilloscope** để nhìn tầng vật lý — mức điện áp differential, thời gian cạnh, phản xạ do trở kháng đầu cuối (termination 120Ω) sai. Nhiều lỗi CAN thực chất là vấn đề tầng vật lý (termination, nhiễu, ground) mà chỉ oscilloscope mới lộ ra, còn logic sai frame thì analyzer bắt. Em trace signal/frame theo yêu cầu khách hàng rồi ghi lại kết quả bằng tiếng Anh.

**Q: Ở Bosch em tự hào nhất việc gì?**
> Ngoài phần CAN, em xây **công cụ tự động hoá Python** cho báo cáo và xử lý dữ liệu lặp đi lặp lại, cộng một trợ lý AI nội bộ để tra cứu tài liệu kỹ thuật — cả hai được đội dùng hằng ngày. Nó cho thấy em không chỉ làm task được giao mà còn tự tìm và bỏ những nút thắt lặp lại của cả nhóm.

**Q: Vì sao rời Bosch để sang Gremsy? (nếu bị hỏi)**
> (Trả lời tích cực, không chê chỗ cũ.) Bosch cho em nền tảng vững về quy trình, chất lượng và CAN ô tô. Nhưng đam mê của em nằm ở giao điểm **drone, video và điều khiển gimbal** — đúng thứ Gremsy làm và đúng thứ em đã tự đầu tư học ngoài giờ. Em muốn làm sản phẩm mà nền tảng embedded và mảng video/điều khiển của em cùng có ích.

---

## Nhóm F — Câu hành vi / soft skills

Chuẩn bị theo **STAR** (Situation – Task – Action – Result). Đây là khung, thay bằng chi tiết thật của bạn.

**Q: Kể một lần em làm leader / dẫn dắt nhóm.**
> (STAR từ đồ án AGV — Team Leader 2 người, và Founder/President UIT Media Club 2 năm.) Ở AGV em vừa dẫn nhóm vừa gánh phần khó nhất là firmware control. Em chia việc theo thế mạnh từng người, tự nhận phần EKF/PID vì nó rủi ro nhất, và giữ nhịp bằng mục tiêu tối thiểu cho từng tuần. Kết quả: hệ chạy được ngoài trời với pose ổn định kể cả khi GPS chập chờn.

**Q: Kể một lần em thất bại hoặc sai, và học được gì.**
> (Dùng câu chuyện thật, rất mạnh, từ dự án này — đã ghi ở [06](06-INTERVIEW-QA.md).) Em từng kết luận "ảnh tĩnh giấu lỗi vỡ hình", nghe rất hợp lý và còn có thí nghiệm "xác nhận". Ba ngày sau em đo lại thì phát hiện ảnh em tưởng là "động" thực ra **đứng yên 0.0%** — giả thuyết sai đã sống trong tài liệu một ngày chỉ vì nó dự đoán đúng cái em đã thấy. Bài học: một dụng cụ mù và một mẫu thử sai có thể **bảo kê lẫn nhau**. Từ đó em luôn đối chiếu bằng dụng cụ thứ hai độc lập trước khi tin một kết luận.

**Q: Em xử lý bất đồng kỹ thuật trong nhóm thế nào?**
> Em kéo về **số liệu**. Thay vì tranh luận ai đúng theo cảm tính, em đề xuất một phép đo nhỏ phân định được. Trong dự án cá nhân em đã quen làm vậy với chính mình — mọi tranh cãi "cái nào chậm hơn" đều kết bằng một lần chạy `GST_TRACERS`. Với nhóm cũng thế: một thí nghiệm rẻ thường rẻ hơn một buổi cãi nhau.

**Q: Em quản lý deadline / ưu tiên khi thiếu thời gian ra sao?**
> Em xếp việc theo tỉ lệ **giá trị / thời gian** và dám cắt. Trong dự án này JD có Yocto nhưng em bỏ hẳn vì nó tốn 4–8 tiếng build để cho ra một dòng `login:` — em dồn giờ đó cho video và MAVLink là phần lõi công việc hằng ngày. Em ghi rõ cái đã cắt và lý do, thay vì làm nửa vời mọi thứ.

**Q: Vì sao chúng tôi nên tuyển em?**
> Vì hai mảng em mạnh — control firmware thời gian thực (EKF/PID, phần cứng thật) và kỹ thuật video/truyền dẫn độ trễ thấp — hội tụ đúng vào giao điểm sản phẩm của Gremsy. Và em làm việc theo kiểu đo-rồi-mới-tin, nên số liệu em đưa ra là số dùng được, không phải số cho đẹp CV.

---

## Nhóm G — Câu em nên hỏi ngược lại

Hỏi ngược thể hiện sự nghiêm túc. Chọn 2–3 câu, đừng hỏi về lương ở vòng kỹ thuật.

- Firmware gimbal của team chạy trên RTOS hay bare-metal, và MCU/SoC dòng nào?
- Vòng điều khiển ổn định chạy tần số bao nhiêu, và bottleneck lớn nhất hiện tại của các anh là latency, độ chính xác IMU, hay nhiễu rung cơ khí?
- Team tích hợp với flight controller qua MAVLink gimbal protocol hay giao thức riêng?
- Quy trình test firmware của team thế nào — có dùng SITL/HIL (hardware-in-the-loop) không?
- Một kỹ sư mới trong 3–6 tháng đầu thường được giao mảng gì?
- Team dùng công cụ đo/debug nào là chính cho vấn đề real-time và hiệu năng?

---

## Tự kiểm tra trước khi phỏng vấn

- `[ ]` Nói trôi bản giới thiệu 30 giây **và** 2 phút, không vấp
- `[ ]` Giải thích được **Kalman predict/update** và **PID từng hạng tử** thành lời cho người không chuyên
- `[ ]` Vẽ được cơ chế **arbitration CAN** trên giấy nháp
- `[ ]` Phân biệt tức thì: `volatile`/atomic, mutex/semaphore, polling/interrupt, stack/heap, I2C/SPI/UART
- `[ ]` Trả lời **mọi** câu ★ ở file này **và** file [06](06-INTERVIEW-QA.md), thành lời
- `[ ]` Kể được 1 câu chuyện **thất bại thật** (đã có sẵn ở 06) theo STAR
- `[ ]` Có sẵn 3 câu hỏi ngược lại nhà tuyển dụng
- `[ ]` Kết nối được **mọi** phần trong CV về bài toán gimbal-trên-drone của Gremsy
