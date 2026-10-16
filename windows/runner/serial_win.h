#ifndef RUNNER_SERIAL_WIN_H_
#define RUNNER_SERIAL_WIN_H_

#include <flutter/binary_messenger.h>

#include <memory>

class SerialWinHost {
 public:
  void Attach(flutter::BinaryMessenger* messenger);
  void Close();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_SERIAL_WIN_H_
