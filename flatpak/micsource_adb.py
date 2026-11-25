"""Shared ADB command construction for MicSource host components."""

DEFAULT_SERVER_PORT = 5038
DEFAULT_SYSTEM_PORT = 5037


def validate_server_port(value):
    """Return a valid MicSource ADB server port or raise ValueError."""
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError("ADB server port must be an integer") from exc
    if not 1024 <= port <= 65535:
        raise ValueError("ADB server port must be between 1024 and 65535")
    if port == DEFAULT_SYSTEM_PORT:
        raise ValueError("ADB server port 5037 is reserved for the system ADB server")
    return port


def command(adb_path, server_port, args, serial=None):
    """Build an argv vector pinned to MicSource's isolated server port."""
    argv = [adb_path, "-P", str(validate_server_port(server_port))]
    if serial:
        argv.extend(("-s", serial))
    argv.extend(args)
    return argv


def server_port_error(server_port, stderr):
    """Return a clear message for an ADB server-port bind/start failure."""
    message = str(stderr or "").strip()
    lowered = message.lower()
    if any(token in lowered for token in (
        "cannot bind", "address already in use", "failed to start daemon",
        "cannot connect to daemon at tcp:localhost:",
    )):
        return f"MicSource ADB server port {server_port} is unavailable: {message}"
    return ""
