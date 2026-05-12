import time, logging
from datetime import datetime
from config import config

logger = logging.getLogger("WickHunter")

class WickHunter:
    def __init__(self, client, risk_mgr):
        self.client = client
        self.risk = risk_mgr
        self.active_positions = {}
        self.last_entry_time = {}
        self.consecutive_losses = 0

    def detect_wick(self, symbol: str):
        df = self.client.get_20s_candles_df(symbol, 100)
        if df.empty or len(df) < 30:
            return None
        # VWAP y VWMA
        df["vwap"] = (df["close"] * df["volume"]).cumsum() / df["volume"].cumsum()
        df["vwma"] = ((df["close"] * df["volume"]).rolling(20).sum() / df["volume"].rolling(20).sum())
        df["dev"] = df["close"] - df["vwma"]
        df["std"] = df["dev"].rolling(20).std()
        df["z"] = df["dev"] / df["std"].replace(0, float("nan"))
        latest = df.iloc[-1]
        z = latest["z"]
        if pd.isna(z):
            return None
        threshold = config.WICK_VWAP_STD_THRESHOLD
        if z < -threshold and latest["close"] > latest["low"] * 1.0002:
            entry = latest["close"]
            sl = entry * (1 - config.WICK_SL_PCT)
            tp = entry * (1 + config.WICK_TP_PCT)
            return {"side": "Buy", "entry": entry, "sl": sl, "tp": tp, "reason": f"Z={z:.2f}"}
        if z > threshold and latest["close"] < latest["high"] * 0.9998:
            entry = latest["close"]
            sl = entry * (1 + config.WICK_SL_PCT)
            tp = entry * (1 - config.WICK_TP_PCT)
            return {"side": "Sell", "entry": entry, "sl": sl, "tp": tp, "reason": f"Z={z:.2f}"}
        return None

    def entry_allowed(self, symbol):
        if symbol in self.active_positions:
            return False
        if self.risk.kill_switch:
            return False
        last = self.last_entry_time.get(symbol)
        if last and (datetime.now() - last).total_seconds() < config.WICK_COOLDOWN_SECONDS:
            return False
        return True

    def execute_signal(self, symbol, signal):
        balance = self.client.get_perp_balance()
        max_exposure = balance * config.WICK_MAX_POSITION_PCT
        self.client.set_leverage(symbol, config.WICK_LEVERAGE)
        qty = max_exposure / signal["entry"]
        resp = self.client.place_market_order(symbol, signal["side"], qty, "linear")
        if not resp:
            return False
        try:
            self.client.http.set_trading_stop(
                category="linear", symbol=symbol, positionIdx=0,
                stopLoss=str(round(signal["sl"],8)),
                takeProfit=str(round(signal["tp"],8)),
                slTriggerBy="MarkPrice", tpTriggerBy="MarkPrice",
            )
        except Exception as e:
            logger.error(f"SL/TP fail: {e}")
        pos = {
            "symbol": symbol,
            "side": signal["side"],
            "entry_price": signal["entry"],
            "sl": signal["sl"],
            "tp": signal["tp"],
            "quantity": qty,
            "time": datetime.now(),
            "order_id": resp.get("orderId"),
        }
        self.active_positions[symbol] = pos
        self.last_entry_time[symbol] = datetime.now()
        logger.info(f"⚡ WICK {signal['side']} {symbol} q={qty:.2f} @{signal['entry']:.8f}")
        return True

    def manage_exits(self):
        for sym, pos in list(self.active_positions.items()):
            current = self.client.last_prices.get(sym)
            if not current:
                continue
            if pos["side"] == "Buy":
                if current <= pos["sl"] or current >= pos["tp"]:
                    self.close_position(pos, current, "exit")
            else:
                if current >= pos["sl"] or current <= pos["tp"]:
                    self.close_position(pos, current, "exit")

    def close_position(self, pos, exit_price, reason):
        side = "Sell" if pos["side"] == "Buy" else "Buy"
        self.client.place_market_order(pos["symbol"], side, pos["quantity"], "linear")
        pnl = (exit_price - pos["entry_price"]) * pos["quantity"] if pos["side"] == "Buy" else (pos["entry_price"] - exit_price) * pos["quantity"]
        self.risk.update_pnl(pnl)
        self.active_positions.pop(pos["symbol"], None)
        logger.info(f"WICK cerrada {pos['symbol']}: PnL=${pnl:.4f}")

    def run(self):
        while True:
            if self.risk.kill_switch or config.STRATEGY_MODE == "FUNDING_ONLY":
                time.sleep(1)
                continue
            for sym in config.WICK_SYMBOLS:
                try:
                    self.manage_exits()
                    if self.entry_allowed(sym):
                        sig = self.detect_wick(sym)
                        if sig:
                            self.execute_signal(sym, sig)
                except Exception as e:
                    logger.error(f"Wick loop error {sym}: {e}")
            time.sleep(0.5)
