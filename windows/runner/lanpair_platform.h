#ifndef LANPAIR_PLATFORM_H_
#define LANPAIR_PLATFORM_H_
#include <flutter/binary_messenger.h>
#include <winsock2.h>
#include <windows.h>
#include <memory>
class LanPairPlatform {
 public:
  static constexpr UINT kEventMessage = WM_APP + 71;
  LanPairPlatform(flutter::BinaryMessenger* messenger, HWND window);
  ~LanPairPlatform();
  void DrainEvents();
 private:
  struct State;
  std::shared_ptr<State> state_;
};
#endif
