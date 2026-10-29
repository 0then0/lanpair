#include "lanpair_platform.h"
#include <gio/gio.h>
#include <cstring>
#include <set>
#include <string>

namespace {
constexpr char kBus[] = "org.freedesktop.Avahi";
constexpr char kServer[] = "org.freedesktop.Avahi.Server";
constexpr char kGroup[] = "org.freedesktop.Avahi.EntryGroup";
constexpr char kBrowser[] = "org.freedesktop.Avahi.ServiceBrowser";
void Put(FlValue* map, const char* key, FlValue* value) { fl_value_set_string_take(map, key, value); }
void Text(FlValue* map, const char* key, const std::string& value) { Put(map, key, fl_value_new_string(value.c_str())); }
std::string String(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
}
int Integer(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_INT ? static_cast<int>(fl_value_get_int(value)) : 0;
}
}

struct LanPairPlatform::State : std::enable_shared_from_this<State> {
  FlMethodChannel* methods = nullptr;
  FlEventChannel* events = nullptr;
  GDBusConnection* bus = nullptr;
  GNetworkMonitor* monitor = nullptr;
  gulong network_handler = 0;
  guint subscription = 0;
  GCancellable* pending = nullptr;
  bool listening = false;
  std::string group, browser, session, device, name;
  std::set<std::string> resolving;
  unsigned generation = 0;

  void Emit(FlValue* value) {
    if (listening) fl_event_channel_send(events, value, nullptr, nullptr);
    fl_value_unref(value);
  }
  void Event(const char* type, const char* code = nullptr) {
    FlValue* value = fl_value_new_map(); Text(value, "type", type);
    if (code) Text(value, "code", code);
    Emit(value);
  }
  GVariant* Call(const std::string& path, const char* interface, const char* method,
                 GVariant* args, GError** error) {
    return g_dbus_connection_call_sync(bus, kBus, path.c_str(), interface, method, args, nullptr,
                                      G_DBUS_CALL_FLAGS_NO_AUTO_START, 1200, nullptr, error);
  }
  bool Available() {
    if (!bus) {
      g_autoptr(GError) error = nullptr;
      bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, &error);
      if (!bus) return false;
    }
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) result = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", kBus), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 500, nullptr, &error);
    gboolean available = FALSE;
    if (result) g_variant_get(result, "(b)", &available);
    return available;
  }
  FlValue* Capabilities() {
    bool available = Available();
    FlValue* result = fl_value_new_map();
    Text(result, "platform", "linux"); Text(result, "osVersion", "Linux");
    Text(result, "permission", "notRequired"); Put(result, "rawMulticast", fl_value_new_bool(true));
    Put(result, "discovery", fl_value_new_bool(available));
    FlValue* limits = fl_value_new_list();
    if (!available) fl_value_append_take(limits, fl_value_new_string("dns_sd_unavailable"));
    Put(result, "limitationCodes", limits); Put(result, "interfaces", fl_value_new_list());
    return result;
  }
  void Stop() {
    generation++;
    if (pending) { g_cancellable_cancel(pending); g_clear_object(&pending); }
    if (bus && subscription) g_dbus_connection_signal_unsubscribe(bus, subscription);
    subscription = 0;
    if (bus && !browser.empty()) { g_autoptr(GVariant) result = Call(browser, kBrowser, "Free", nullptr, nullptr); }
    if (bus && !group.empty()) { g_autoptr(GVariant) result = Call(group, kGroup, "Free", nullptr, nullptr); }
    browser.clear(); group.clear(); resolving.clear();
  }
  void Resolve(GVariant* signal) {
    gint interface_index, protocol; guint flags;
    const gchar *service, *type, *domain;
    g_variant_get(signal, "(ii&s&s&su)", &interface_index, &protocol, &service, &type, &domain, &flags);
    std::string service_name(service);
    if (service_name == name || service_name.rfind("LP-" + session.substr(0, 16) + "-", 0) != 0 || resolving.size() >= 8 ||
        !resolving.insert(service_name + ":" + std::to_string(interface_index)).second) return;
    struct Query { std::shared_ptr<State> state; unsigned generation; };
    auto* query = new Query{shared_from_this(), generation};
    g_dbus_connection_call(bus, kBus, "/", kServer, "ResolveService",
        g_variant_new("(iisssiu)", interface_index, protocol, service, type, domain, -1, 0u),
        G_VARIANT_TYPE("(iissssisqaayu)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 2500, pending,
        [](GObject* object, GAsyncResult* async, gpointer context) {
          std::unique_ptr<Query> query(static_cast<Query*>(context));
          g_autoptr(GError) error = nullptr;
          g_autoptr(GVariant) result = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), async, &error);
          State* self = query->state.get();
          // Stop cancels queries; queued callbacks still finish on the GTK main context.
          if (!result || query->generation != self->generation) return;
          gint index, protocol_, family; guint flags_;
          guint16 port; const gchar *name_, *type_, *domain_, *host, *address;
          g_autoptr(GVariant) txt = nullptr;
          g_variant_get(result, "(ii&s&s&s&si&sq@aayu)", &index, &protocol_, &name_, &type_, &domain_, &host,
                        &family, &address, &port, &txt, &flags_);
          std::string session_, device_;
          for (gsize i = 0; i < g_variant_n_children(txt) && i < 32; i++) {
            g_autoptr(GVariant) item = g_variant_get_child_value(txt, i);
            gsize length = 0;
            const auto* bytes = static_cast<const char*>(g_variant_get_fixed_array(item, &length, 1));
            if (length > 255) continue;
            std::string field(bytes, length);
            if (field.rfind("session=", 0) == 0) session_ = field.substr(8);
            if (field.rfind("device=", 0) == 0) device_ = field.substr(7);
          }
          if (session_ != self->session || device_.empty() || device_ == self->device) return;
          FlValue* event = fl_value_new_map(); Text(event, "type", "resolved"); Text(event, "name", name_);
          Text(event, "host", host); Text(event, "sessionId", session_); Text(event, "deviceId", device_);
          Put(event, "port", fl_value_new_int(port)); Put(event, "interfaceIndex", fl_value_new_int(index));
          std::string scoped(address);
          if (family == 1 && scoped.rfind("fe80:", 0) == 0 && scoped.find('%') == std::string::npos)
            scoped += "%" + std::to_string(index);
          FlValue* addresses = fl_value_new_list(); fl_value_append_take(addresses, fl_value_new_string(scoped.c_str()));
          Put(event, "addresses", addresses); self->Emit(event);
        }, query);
  }
  bool Start(FlValue* args, GError** error) {
    Stop(); if (!Available()) return false;
    session = String(args, "sessionId"); device = String(args, "deviceId");
    int port = Integer(args, "port"); int index = Integer(args, "interfaceIndex"); if (index <= 0) index = -1;
    if (session.empty() || session.size() > 128 || device.empty() || device.size() > 128 || port <= 0 || port > 65535) return false;
    name = "LP-" + session.substr(0, 16) + "-" + device.substr(0, 16);
    pending = g_cancellable_new();
    subscription = g_dbus_connection_signal_subscribe(bus, kBus, nullptr, nullptr, nullptr, nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE,
        [](GDBusConnection*, const gchar*, const gchar* path, const gchar* interface,
           const gchar* signal, GVariant* args_, gpointer data) {
          auto* self = static_cast<State*>(data);
          if (self->browser == path && std::strcmp(interface, kBrowser) == 0) {
            if (std::strcmp(signal, "ItemNew") == 0) self->Resolve(args_);
            else if (std::strcmp(signal, "Failure") == 0) self->Event("error", "dns_sd_browse");
          } else if (self->group == path && std::strcmp(signal, "StateChanged") == 0) {
            gint state; const gchar* message; g_variant_get(args_, "(i&s)", &state, &message);
            if (state == 2) { FlValue* event = fl_value_new_map(); Text(event, "type", "published"); Text(event, "name", self->name); self->Emit(event); }
            else if (state == 3 || state == 4) self->Event("error", "dns_sd_publish");
          }
        }, this, nullptr);
    g_autoptr(GVariant) entry = Call("/", kServer, "EntryGroupNew", nullptr, error);
    if (!entry) return false;
    const gchar* path; g_variant_get(entry, "(&o)", &path); group = path;
    GVariantBuilder txt; g_variant_builder_init(&txt, G_VARIANT_TYPE("aay"));
    for (const auto& field : {"session=" + session, "device=" + device})
      g_variant_builder_add_value(&txt, g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, field.data(), field.size(), 1));
    g_autoptr(GVariant) added = Call(group, kGroup, "AddService",
        g_variant_new("(iiussssq@aay)", index, -1, 0u, name.c_str(), "_lanpair._tcp", "local", "", port,
                      g_variant_builder_end(&txt)), error);
    if (!added) return false;
    g_autoptr(GVariant) committed = Call(group, kGroup, "Commit", nullptr, error);
    if (!committed) return false;
    g_autoptr(GVariant) browse = Call("/", kServer, "ServiceBrowserNew",
        g_variant_new("(iissu)", index, -1, "_lanpair._tcp", "local", 0u), error);
    if (!browse) return false;
    g_variant_get(browse, "(&o)", &path); browser = path;
    return true;
  }
};

LanPairPlatform::LanPairPlatform(FlBinaryMessenger* messenger) : state_(std::make_shared<State>()) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  state_->methods = fl_method_channel_new(messenger, "lanpair/platform", FL_METHOD_CODEC(codec));
  state_->events = fl_event_channel_new(messenger, "lanpair/discovery", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(state_->events,
      [](FlEventChannel*, FlValue*, gpointer data) -> FlMethodErrorResponse* { static_cast<State*>(data)->listening = true; return nullptr; },
      [](FlEventChannel*, FlValue*, gpointer data) -> FlMethodErrorResponse* { static_cast<State*>(data)->listening = false; return nullptr; }, state_.get(), nullptr);
  fl_method_channel_set_method_call_handler(state_->methods,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
        auto* self = static_cast<State*>(data); const char* method = fl_method_call_get_name(call);
        if (std::strcmp(method, "capabilities") == 0 || std::strcmp(method, "requestPermission") == 0) {
          g_autoptr(FlValue) result = self->Capabilities(); fl_method_call_respond_success(call, result, nullptr);
        } else if (std::strcmp(method, "startDiscovery") == 0) {
          g_autoptr(GError) error = nullptr;
          if (self->Start(fl_method_call_get_args(call), &error)) fl_method_call_respond_success(call, nullptr, nullptr);
          else { self->Stop(); fl_method_call_respond_error(call, "dns_sd_unavailable", "Avahi could not start DNS-SD.", nullptr, nullptr); }
        } else if (std::strcmp(method, "stopDiscovery") == 0) { self->Stop(); fl_method_call_respond_success(call, nullptr, nullptr); }
        else if (std::strcmp(method, "acquireMulticast") == 0 || std::strcmp(method, "releaseMulticast") == 0)
          fl_method_call_respond_success(call, nullptr, nullptr);
        else if (std::strcmp(method, "openSettings") == 0)
          fl_method_call_respond_error(call, "settings_unavailable", "Linux has no common local network permission settings page.", nullptr, nullptr);
        else fl_method_call_respond_not_implemented(call, nullptr);
      }, state_.get(), nullptr);
  state_->monitor = G_NETWORK_MONITOR(g_object_ref(g_network_monitor_get_default()));
  state_->network_handler = g_signal_connect(state_->monitor, "network-changed", G_CALLBACK(+[](GNetworkMonitor*, gboolean, gpointer data) {
    static_cast<State*>(data)->Event("networkChanged");
  }), state_.get());
}

LanPairPlatform::~LanPairPlatform() {
  state_->Stop();
  if (state_->network_handler) g_signal_handler_disconnect(state_->monitor, state_->network_handler);
  fl_method_channel_set_method_call_handler(state_->methods, nullptr, nullptr, nullptr);
  fl_event_channel_set_stream_handlers(state_->events, nullptr, nullptr, nullptr, nullptr);
  g_clear_object(&state_->monitor);
  g_clear_object(&state_->methods); g_clear_object(&state_->events); g_clear_object(&state_->bus);
  // Cancelled async queries retain State until their completion handlers have drained.
  state_.reset();
}
