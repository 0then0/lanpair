#ifndef LANPAIR_PLATFORM_H_
#define LANPAIR_PLATFORM_H_
#include <flutter_linux/flutter_linux.h>
#include <memory>
// The returned object is owned by the runner and must be destroyed before its engine.
class LanPairPlatform {
 public:
  explicit LanPairPlatform(FlBinaryMessenger* messenger);
  ~LanPairPlatform();
 private:
  struct State;
  std::shared_ptr<State> state_;
};
#endif
