cmake_minimum_required(VERSION 3.16)
project(drone_video_receiver LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)  # keep symbols: valgrind and gdb need them
endif()

# GStreamer ships pkg-config files, not CMake config packages. IMPORTED_TARGET
# turns them into PkgConfig::GST so include dirs and link flags propagate.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET
  gstreamer-1.0
  gstreamer-app-1.0
)

add_executable(receiver src/receiver.cpp)
target_link_libraries(receiver PRIVATE PkgConfig::GST)
target_compile_options(receiver PRIVATE -Wall -Wextra -Wpedantic)
