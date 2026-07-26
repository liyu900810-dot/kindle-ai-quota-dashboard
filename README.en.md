# Kindle AI Quota Dashboard

A privacy-conscious dashboard that displays local AI service quota snapshots on a jailbroken Kindle.

The project separates local collection from the static e-ink page. It supports a private LAN deployment or a user-owned static host for Kindles that move between Wi-Fi networks.

All providers are disabled by default. Demo mode uses fake data and reads no credentials.

```powershell
npm.cmd run demo
npm.cmd run build
npm.cmd run serve
```

Before enabling real providers or public hosting, read [SECURITY.md](SECURITY.md) and [docs/privacy.md](docs/privacy.md).

The project is not affiliated with Anthropic, OpenAI, Moonshot AI, DeepSeek, or Amazon. Product names are used only to describe compatibility.

Licensed under the [MIT License](LICENSE).
