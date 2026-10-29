#include <winsock2.h>
#include "lanpair_platform.h"
#include <ws2tcpip.h>
#include <windns.h>
#include <shellapi.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <atomic>
#include <deque>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
std::wstring Wide(const std::string& text) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.c_str(), -1, nullptr, 0);
  if (!count) return L"";
  std::wstring result(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.c_str(), -1, result.data(), count);
  result.pop_back(); return result;
}
std::string UTF8(const wchar_t* text) {
  if (!text) return "";
  int count = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (!count) return "";
  std::string result(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), count, nullptr, nullptr);
  result.pop_back(); return result;
}
std::string String(const Map& map, const char* key) {
  auto entry = map.find(Value(key)); if (entry == map.end()) return "";
  auto* text = std::get_if<std::string>(&entry->second); return text ? *text : "";
}
int Number(const Map& map, const char* key) {
  auto entry = map.find(Value(key)); if (entry == map.end()) return 0;
  if (auto* value = std::get_if<int32_t>(&entry->second)) return *value;
  if (auto* value = std::get_if<int64_t>(&entry->second)) return static_cast<int>(*value);
  return 0;
}
}

struct LanPairPlatform::State : std::enable_shared_from_this<State> {
  struct Operation {
    std::weak_ptr<State> owner;
    unsigned generation = 0;
    std::wstring name, host;
    std::string session, device;
    ULONG interface_index = 0;
    DNS_SERVICE_CANCEL cancel{};
    DNS_SERVICE_REGISTER_REQUEST registration{};
    DNS_SERVICE_BROWSE_REQUEST browse{};
    DNS_SERVICE_RESOLVE_REQUEST resolve{};
    PDNS_SERVICE_INSTANCE instance = nullptr;
    std::atomic<bool> stopping{false}, registered{false}, deregistering{false};
    ~Operation() { if (instance) DnsServiceFreeInstance(instance); }
  };
  using Context = std::shared_ptr<Operation>;
  HWND window = nullptr;
  std::unique_ptr<flutter::MethodChannel<Value>> methods;
  std::unique_ptr<flutter::EventChannel<Value>> events;
  std::unique_ptr<flutter::EventSink<Value>> sink;
  std::shared_ptr<Operation> registration, browsing;
  std::vector<std::weak_ptr<Operation>> resolutions;
  std::mutex mutex;
  std::deque<Value> queue;
  std::set<std::wstring> resolved_names;
  std::atomic<unsigned> generation{0};
  std::atomic<bool> alive{true};
  HANDLE network_subscription = nullptr;
  HANDLE address_subscription = nullptr;
  std::string session, device;
  ULONG interface_index = 0;

  void Queue(Map event, unsigned current) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!alive || generation != current || queue.size() >= 64) return;
    queue.emplace_back(std::move(event)); PostMessage(window, LanPairPlatform::kEventMessage, 0, 0);
  }
  void Error(const char* code, DWORD status, unsigned current) {
    Queue(Map{{Value("type"), Value("error")}, {Value("code"), Value(code)},
              {Value("nativeCode"), Value(static_cast<int64_t>(status))}}, current);
  }
  Value Capabilities() {
    // DNS-SD is native on supported Windows 10/11; actual service failures remain explicit observations.
    return Value(Map{{Value("platform"), Value("windows")}, {Value("osVersion"), Value("Windows")},
      {Value("permission"), Value("notRequired")}, {Value("rawMulticast"), Value(true)},
      {Value("discovery"), Value(true)}, {Value("limitationCodes"), Value(List{})}, {Value("interfaces"), Value(List{})}});
  }
  std::shared_ptr<Operation> MakeOperation(const std::shared_ptr<Operation>& source = nullptr) {
    auto op = std::make_shared<Operation>(); op->owner = shared_from_this();
    op->generation = source ? source->generation : generation.load();
    op->session = source ? source->session : session; op->device = source ? source->device : device;
    op->interface_index = source ? source->interface_index : interface_index;
    return op;
  }
  static void Deregister(const std::shared_ptr<Operation>& op) {
    if (op->deregistering.exchange(true)) return;
    auto* context = new Context(op);
    op->registration.pQueryContext = context;
    op->registration.pRegisterCompletionCallback = [](DWORD, PVOID context_, PDNS_SERVICE_INSTANCE instance) {
      std::unique_ptr<Context> hold(static_cast<Context*>(context_));
      if (instance && instance != (*hold)->instance) DnsServiceFreeInstance(instance);
    };
    DWORD status = DnsServiceDeRegister(&op->registration, nullptr);
    if (status != DNS_REQUEST_PENDING) delete context;
  }
  void Stop() {
    generation++;
    auto publish = std::move(registration); auto browse = std::move(browsing);
    std::vector<std::shared_ptr<Operation>> queries;
    {
      std::lock_guard<std::mutex> lock(mutex);
      for (auto& weak : resolutions) if (auto op = weak.lock()) queries.push_back(op);
      resolutions.clear(); resolved_names.clear(); queue.clear();
    }
    if (publish) {
      publish->stopping = true;
      if (publish->registered) Deregister(publish);
      else DnsServiceRegisterCancel(&publish->cancel);
    }
    if (browse) { browse->stopping = true; DnsServiceBrowseCancel(&browse->cancel); }
    for (auto& op : queries) { op->stopping = true; DnsServiceResolveCancel(&op->cancel); }
  }
  void ResolveName(const std::wstring& name, const std::shared_ptr<Operation>& source) {
    unsigned current = source->generation;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (generation != current || resolved_names.size() >= 8 || !resolved_names.insert(name).second) return;
    }
    auto op = MakeOperation(source); op->name = name;
    op->resolve.Version = DNS_QUERY_REQUEST_VERSION1; op->resolve.InterfaceIndex = op->interface_index;
    op->resolve.QueryName = op->name.data();
    auto* context = new Context(op); op->resolve.pQueryContext = context;
    op->resolve.pResolveCompletionCallback = [](DWORD status, PVOID context_, PDNS_SERVICE_INSTANCE instance) {
      std::unique_ptr<Context> hold(static_cast<Context*>(context_)); auto op_ = *hold;
      auto self = op_->owner.lock();
      if (self && !op_->stopping && self->generation == op_->generation && status == ERROR_SUCCESS && instance) {
        std::string session_, device_;
        for (DWORD i = 0; instance->keys && instance->values && i < instance->dwPropertyCount && i < 32; i++) {
          if (!instance->keys[i] || !instance->values[i]) continue;
          if (std::wstring(instance->keys[i]) == L"session") session_ = UTF8(instance->values[i]);
          if (std::wstring(instance->keys[i]) == L"device") device_ = UTF8(instance->values[i]);
        }
        if (session_ == op_->session && !device_.empty() && device_ != op_->device) {
          List addresses; char buffer[INET6_ADDRSTRLEN]{};
          if (instance->ip4Address && InetNtopA(AF_INET, instance->ip4Address, buffer, sizeof(buffer))) addresses.emplace_back(buffer);
          if (instance->ip6Address && InetNtopA(AF_INET6, instance->ip6Address, buffer, sizeof(buffer))) {
            std::string address(buffer);
            if (address.rfind("fe80:", 0) == 0) address += "%" + std::to_string(instance->dwInterfaceIndex);
            addresses.emplace_back(address);
          }
          self->Queue(Map{{Value("type"), Value("resolved")}, {Value("name"), Value(UTF8(instance->pszInstanceName))},
            {Value("host"), Value(UTF8(instance->pszHostName))}, {Value("addresses"), Value(addresses)},
            {Value("port"), Value(static_cast<int32_t>(instance->wPort))},
            {Value("interfaceIndex"), Value(static_cast<int64_t>(instance->dwInterfaceIndex))},
            {Value("sessionId"), Value(session_)}, {Value("deviceId"), Value(device_)}}, op_->generation);
        }
      } else if (self && status != ERROR_CANCELLED && !op_->stopping) self->Error("dns_sd_resolve", status, op_->generation);
      if (instance) DnsServiceFreeInstance(instance);
    };
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (generation != current) { delete context; return; }
      resolutions.push_back(op);
    }
    DWORD status = DnsServiceResolve(&op->resolve, &op->cancel);
    if (status != DNS_REQUEST_PENDING) { delete context; Error("dns_sd_resolve", status, current); }
    else if (op->stopping) DnsServiceResolveCancel(&op->cancel);
  }
  DWORD Start(const Map& args) {
    Stop(); session = String(args, "sessionId"); device = String(args, "deviceId");
    int port = Number(args, "port"); interface_index = static_cast<ULONG>(Number(args, "interfaceIndex"));
    if (session.empty() || session.size() > 128 || device.empty() || device.size() > 128 || port < 1 || port > 65535)
      return ERROR_INVALID_PARAMETER;
    registration = MakeOperation(); auto op = registration;
    op->name = Wide("LP-" + session.substr(0, 16) + "-" + device.substr(0, 16) + "._lanpair._tcp.local");
    wchar_t host[MAX_COMPUTERNAME_LENGTH + 1]{}; DWORD length = MAX_COMPUTERNAME_LENGTH + 1;
    GetComputerNameW(host, &length); op->host = std::wstring(host) + L".local";
    std::wstring session_w = Wide(session), device_w = Wide(device);
    PCWSTR keys[] = {L"session", L"device"}; PCWSTR values[] = {session_w.c_str(), device_w.c_str()};
    op->instance = DnsServiceConstructInstance(op->name.c_str(), op->host.c_str(), nullptr, nullptr,
                                              static_cast<WORD>(port), 0, 0, 2, keys, values);
    if (!op->instance) return ERROR_NOT_ENOUGH_MEMORY;
    op->registration.Version = DNS_QUERY_REQUEST_VERSION1; op->registration.InterfaceIndex = interface_index;
    op->registration.pServiceInstance = op->instance; op->registration.unicastEnabled = FALSE;
    auto* publish_context = new Context(op); op->registration.pQueryContext = publish_context;
    op->registration.pRegisterCompletionCallback = [](DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
      std::unique_ptr<Context> hold(static_cast<Context*>(context)); auto op_ = *hold;
      if (instance && instance != op_->instance) {
        DnsServiceFreeInstance(op_->instance); op_->instance = instance; op_->registration.pServiceInstance = instance;
      }
      if (status == ERROR_SUCCESS) {
        op_->registered = true;
        if (op_->stopping) { Deregister(op_); return; }
        if (auto self = op_->owner.lock()) self->Queue(Map{{Value("type"), Value("published")},
          {Value("name"), Value(UTF8(op_->name.c_str()))}}, op_->generation);
      } else if (auto self = op_->owner.lock()) self->Error("dns_sd_publish", status, op_->generation);
    };
    DWORD status = DnsServiceRegister(&op->registration, &op->cancel);
    if (status != DNS_REQUEST_PENDING) { delete publish_context; return status; }
    browsing = MakeOperation(); auto browse = browsing;
    browse->name = L"_lanpair._tcp.local"; browse->browse.Version = DNS_QUERY_REQUEST_VERSION1;
    browse->browse.InterfaceIndex = interface_index; browse->browse.QueryName = browse->name.c_str();
    auto* browse_context = new Context(browse); browse->browse.pQueryContext = browse_context;
    browse->browse.pBrowseCallback = [](DWORD status_, PVOID context, PDNS_RECORD records) {
      auto op_ = *static_cast<Context*>(context);
      auto self = op_->owner.lock();
      if (self && !op_->stopping && status_ == ERROR_SUCCESS) {
        for (PDNS_RECORD item = records; item; item = item->pNext) {
          if (item->wType != DNS_TYPE_PTR || !item->Data.PTR.pNameHost) continue;
          std::wstring service(item->Data.PTR.pNameHost);
          std::wstring prefix = Wide("LP-" + op_->session.substr(0, 16) + "-");
          std::wstring own = Wide("LP-" + op_->session.substr(0, 16) + "-" + op_->device.substr(0, 16) + ".");
          if (service.rfind(prefix, 0) == 0 && service.rfind(own, 0) != 0) self->ResolveName(service, op_);
        }
      } else if (self && status_ != ERROR_CANCELLED && !op_->stopping)
        self->Error("dns_sd_browse", status_, op_->generation);
      if (records) DnsRecordListFree(records, DnsFreeRecordList);
      // Windows guarantees a final ERROR_CANCELLED callback after BrowseCancel.
      if (status_ == ERROR_CANCELLED) delete static_cast<Context*>(context);
    };
    status = DnsServiceBrowse(&browse->browse, &browse->cancel);
    if (status != DNS_REQUEST_PENDING) { delete browse_context; return status; }
    return ERROR_SUCCESS;
  }
};

LanPairPlatform::LanPairPlatform(flutter::BinaryMessenger* messenger, HWND window)
    : state_(std::make_shared<State>()) {
  state_->window = window; auto* codec = &flutter::StandardMethodCodec::GetInstance();
  NotifyIpInterfaceChange(AF_UNSPEC, [](PVOID context, PMIB_IPINTERFACE_ROW, MIB_NOTIFICATION_TYPE) {
    auto* self = static_cast<State*>(context);
    self->Queue(Map{{Value("type"), Value("networkChanged")}}, self->generation);
  }, state_.get(), FALSE, &state_->network_subscription);
  NotifyUnicastIpAddressChange(AF_UNSPEC, [](PVOID context, PMIB_UNICASTIPADDRESS_ROW, MIB_NOTIFICATION_TYPE) {
    auto* self = static_cast<State*>(context);
    self->Queue(Map{{Value("type"), Value("networkChanged")}}, self->generation);
  }, state_.get(), FALSE, &state_->address_subscription);
  state_->methods = std::make_unique<flutter::MethodChannel<Value>>(messenger, "lanpair/platform", codec);
  state_->events = std::make_unique<flutter::EventChannel<Value>>(messenger, "lanpair/discovery", codec);
  std::weak_ptr<State> weak = state_;
  state_->events->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
    [weak](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink) -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
      if (auto self = weak.lock()) self->sink = std::move(sink); return nullptr;
    },
    [weak](const Value*) -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
      if (auto self = weak.lock()) self->sink.reset(); return nullptr;
    }));
  state_->methods->SetMethodCallHandler([weak](const auto& call, auto result) {
    auto self = weak.lock(); if (!self) { result->Error("cancelled"); return; }
    const auto& method = call.method_name();
    if (method == "capabilities" || method == "requestPermission") result->Success(self->Capabilities());
    else if (method == "startDiscovery") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      DWORD status = args ? self->Start(*args) : ERROR_INVALID_PARAMETER;
      if (status == ERROR_SUCCESS) result->Success();
      else { self->Stop(); result->Error("dns_sd_unavailable", "Windows DNS-SD could not start.", Value(static_cast<int64_t>(status))); }
    } else if (method == "stopDiscovery") { self->Stop(); result->Success(); }
    else if (method == "acquireMulticast" || method == "releaseMulticast") result->Success();
    else if (method == "openSettings") {
      ShellExecuteW(nullptr, L"open", L"ms-settings:network-status", nullptr, nullptr, SW_SHOWNORMAL); result->Success();
    } else result->NotImplemented();
  });
}
LanPairPlatform::~LanPairPlatform() {
  state_->alive = false;
  if (state_->network_subscription) CancelMibChangeNotify2(state_->network_subscription);
  if (state_->address_subscription) CancelMibChangeNotify2(state_->address_subscription);
  state_->Stop(); state_->events.reset(); state_->methods.reset(); state_->sink.reset();
}
void LanPairPlatform::DrainEvents() {
  std::deque<Value> events;
  { std::lock_guard<std::mutex> lock(state_->mutex); events.swap(state_->queue); }
  for (auto& event : events) if (state_->sink) state_->sink->Success(event);
}
