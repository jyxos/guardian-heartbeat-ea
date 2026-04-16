# Guardian Heartbeat EA v3.0

A timer-only Expert Advisor for MetaTrader 5 that writes a JSON heartbeat file every 15 seconds. It does not trade, does not modify orders, and does not interact with the broker.

## What it does

Guardian Heartbeat runs as a single EA on one chart per terminal. Every 15 seconds, it writes a JSON file to the terminal's `MQL5/Files/` directory containing 46 fields of terminal state data:

- Account balance, equity, free margin, margin used
- Broker connection status and round-trip time (RTT)
- Open positions count and floating P&L
- EA statuses across all charts (name, symbol, timeframe, alive/frozen)
- Recent trade history
- Daily session statistics (trades, volume, realized P&L)
- Pending order tracking
- Terminal build, server name, account number

The EA is read-only. It observes the terminal and writes a file. Nothing else.

## Installation

1. Copy `Guardian_Heartbeat.mq5` to your MetaTrader 5 `MQL5/Experts/` directory
2. Compile in MetaEditor (F7)
3. Attach to any chart on the terminal you want to monitor
4. Enable "Allow DLL imports" is **not required** — the EA uses only standard MQL5 functions

One EA per terminal. Attach it to one chart only.

## Output

The EA writes to `MQL5/Files/guardian_heartbeat.json`. The file is overwritten every 15 seconds. Any external process can read this file to determine terminal state.

## Designed for Sentinel MT

Guardian Heartbeat is the companion EA for [Sentinel MT](https://jyxos.com/sentinel-mt), a 24/7 watchdog and crash recovery tool for MetaTrader 5. Sentinel reads the heartbeat file to detect frozen EAs, broker disconnections, equity anomalies, and terminal health issues.

The EA works independently of Sentinel and can be used as a standalone terminal state exporter for any monitoring, logging, or alerting system.

## License

MIT License. See [LICENSE](LICENSE) for details.

## Links

- [Sentinel MT](https://jyxos.com/sentinel-mt) — 24/7 monitoring and crash recovery for MetaTrader 5
- [Downloads](https://jyxos.com/resources/downloads) — Free utilities for systematic trading operators
- [JYXOS](https://jyxos.com) — Infrastructure software for operators running systematic strategies

---

Copyright 2026 Marcelo Borasi / JYXOS
