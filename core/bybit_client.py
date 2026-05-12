import os, json, time, threading, logging
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple
import numpy as np
import pandas as pd
import websocket
from pybit.unified_trading import HTTP
from config import config

logger = logging.getLogger("BybitClient")

class BybitClient:
    def __init__(self, cfg):
        self.cfg = cfg
        self.http = HTTP(
            testnet=cfg.TESTNET,
            api_key=cfg.BYBIT_API_KEY,
            api_secret=cfg.BYBIT_API_SECRET,
        )
        self.lock = threading.Lock()
        self.last_prices: Dict[str, float] = {}
        self.ticks: Dict[str, List[Tuple[datetime, float, float]]] = {s: [] for s in cfg.WICK_SYMBOLS}
        self.ws_connected = False
        self.stop_ws = False
        self._check_connection()

    def _check_connection(self):
        try:
            resp = self.http.get_wallet_balance(accountType="UNIFIED")
            total = float(resp["result"]["list"][0]["totalEquity"])
            logger.info(f"✅ Conectado. Balance: ${total:.2f}")
        except Exception as e:
            logger.error(f"❌ Fallo autenticación: {e}")
            raise

    def set_leverage(self, symbol: str, leverage: int):
        try:
            self.http.set_leverage(
                category="linear", symbol=symbol,
                buyLeverage=str(leverage), sellLeverage=str(leverage),
            )
        except Exception as e:
            logger.warning(f"No se pudo ajustar leverage {symbol}: {e}")

    def place_market_order(self, symbol: str, side: str, qty: float, category="linear"):
        try:
            resp = self.http.place_order(
                category=category, symbol=symbol, side=side,
                orderType="Market", qty=str(qty), timeInForce="IOC",
            )
            if resp["retCode"] == 0:
                return resp["result"]
            else:
                logger.error(f"Orden fallida: {resp['retMsg']}")
        except Exception as e:
            logger.error(f"Excepción orden: {e}")
        return None

    def place_limit_order(self, symbol, side, qty, price, category="linear"):
        try:
            resp = self.http.place_order(
                category=category, symbol=symbol, side=side,
                orderType="Limit", qty=str(qty), price=str(round(price,8)),
                timeInForce="GTC",
            )
            if resp["retCode"] == 0:
                return resp["result"]
        except Exception as e:
            logger.error(f"Limit falló: {e}")
        return None

    def get_perp_balance(self):
        try:
            resp = self.http.get_wallet_balance(accountType="UNIFIED")
            return float(resp["result"]["list"][0]["totalEquity"])
        except:
            return config.INITIAL_CAPITAL

    def get_spot_balance(self, coin="USDT"):
        try:
            resp = self.http.get_wallet_balance(accountType="SPOT")
            for item in resp["result"]["list"][0]["coin"]:
                if item["coin"] == coin:
                    return float(item["walletBalance"])
        except:
            pass
        return 0.0

    def start_trade_stream(self, symbols: List[str]):
        ws_url = "wss://stream-testnet.bybit.com/v5/public/linear" if self.cfg.TESTNET else \
                 "wss://stream.bybit.com/v5/public/linear"
        def on_message(ws, message):
            try:
                data = json.loads(message)
                if "topic" not in data or "publicTrade" not in data["topic"]:
                    return
                symbol = data["topic"].split(".")[-1]
                trades = data.get("data", [])
                with self.lock:
                    for t in trades:
                        ts = datetime.fromtimestamp(int(t["T"])/1000.0)
                        price = float(t["p"])
                        volume = float(t["v"])
                        self.last_prices[symbol] = price
                        self.ticks[symbol].append((ts, price, volume))
                # limpiar ticks >5 min
                cutoff = datetime.now() - timedelta(minutes=5)
                self.ticks[symbol] = [(ts,p,v) for ts,p,v in self.ticks[symbol] if ts > cutoff]
            except Exception as e:
                logger.error(f"WS msg error: {e}")
        def on_error(ws, error):
            logger.error(f"WS error: {error}")
        def on_close(ws, status, msg):
            logger.warning("WS cerrado")
            self.ws_connected = False
        def on_open(ws):
            self.ws_connected = True
            args = [f"publicTrade.{s}" for s in symbols]
            ws.send(json.dumps({"op": "subscribe", "args": args}))
            logger.info(f"📡 WS suscrito a {symbols}")
        self.ws = websocket.WebSocketApp(ws_url, on_open=on_open, on_message=on_message,
                                         on_error=on_error, on_close=on_close)
        wst = threading.Thread(target=self.ws.run_forever, kwargs={"ping_interval":20,"ping_timeout":10})
        wst.daemon = True
        wst.start()
        time.sleep(2)

    def get_20s_candles_df(self, symbol: str, n: int = 100) -> pd.DataFrame:
        now = datetime.now()
        bins = [now - timedelta(seconds=20*i) for i in range(n, -1, -1)]
        candles = []
        for b in bins:
            bin_start = b.replace(second=(b.second//20)*20, microsecond=0)
            bin_end = bin_start + timedelta(seconds=20)
            with self.lock:
                ticks = [(t,p,v) for t,p,v in self.ticks.get(symbol,[]) if bin_start <= t < bin_end]
            if ticks:
                prices = [p for _,p,_ in ticks]
                volumes = [v for _,_,v in ticks]
                candles.append({
                    "timestamp": bin_start,
                    "open": prices[0],
                    "high": max(prices),
                    "low": min(prices),
                    "close": prices[-1],
                    "volume": sum(volumes),
                })
        return pd.DataFrame(candles).sort_values("timestamp")
