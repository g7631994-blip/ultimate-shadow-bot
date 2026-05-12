
#!/bin/bash
# ⚡ ULTIMATE SHADOW BOT CORE — Generador de proyecto
set -e

echo "📦 Creando estructura de carpetas..."
mkdir -p core static

# ============================================
# .env.example
# ============================================
cat > .env.example << 'EOF'
BYBIT_API_KEY=TU_API_KEY
BYBIT_API_SECRET=TU_API_SECRET
BYBIT_TESTNET=true

STRATEGY_MODE=AUTO          # WICK_ONLY, FUNDING_ONLY, AUTO

WICK_SYMBOLS=PEPEUSDT,BONKUSDT,FLOKIUSDT,XRPUSDT
WICK_LEVERAGE=3
WICK_MAX_POSITION_PCT=0.05
WICK_SL_PCT=0.002
WICK_TP_PCT=0.005
WICK_VWAP_STD_THRESHOLD=2.5

FUNDING_SYMBOLS=PEPEUSDT,BONKUSDT,FLOKIUSDT,DOGEUSDT,XRPUSDT,INJUSDT,WIFUSDT
FUNDING_THRESHOLD_PCT=0.0005
FUNDING_MIN_NET_RETURN=0.001

MAX_DAILY_LOSS_PCT=0.15
MAX_CONSECUTIVE_LOSSES=5
INITIAL_CAPITAL=100.0

BACKTEST_DEFAULT_DAYS=15
MONTE_CARLO_SIMULATIONS=1000

DATABASE_URL=sqlite:///trades.db
EOF

# ============================================
# requirements.txt
# ============================================
cat > requirements.txt << 'EOF'
fastapi>=0.104.0
uvicorn[standard]
pybit>=5.8.0
websocket-client
python-dotenv
pandas
numpy
matplotlib
scipy
sqlalchemy
EOF

# ============================================
# config.py
# ============================================
cat > config.py << 'EOF'
import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    BYBIT_API_KEY = os.getenv("BYBIT_API_KEY")
    BYBIT_API_SECRET = os.getenv("BYBIT_API_SECRET")
    TESTNET = os.getenv("BYBIT_TESTNET", "true").lower() == "true"

    STRATEGY_MODE = os.getenv("STRATEGY_MODE", "AUTO")

    WICK_SYMBOLS = [s.strip() for s in os.getenv("WICK_SYMBOLS", "PEPEUSDT,BONKUSDT").split(",")]
    WICK_LEVERAGE = int(os.getenv("WICK_LEVERAGE", 3))
    WICK_MAX_POSITION_PCT = float(os.getenv("WICK_MAX_POSITION_PCT", 0.05))
    WICK_SL_PCT = float(os.getenv("WICK_SL_PCT", 0.002))
    WICK_TP_PCT = float(os.getenv("WICK_TP_PCT", 0.005))
    WICK_VWAP_STD_THRESHOLD = float(os.getenv("WICK_VWAP_STD_THRESHOLD", 2.5))
    WICK_CANDLE_SECONDS = 20
    WICK_COOLDOWN_SECONDS = 10

    FUNDING_SYMBOLS = [s.strip() for s in os.getenv("FUNDING_SYMBOLS", "PEPEUSDT").split(",")]
    FUNDING_THRESHOLD_PCT = float(os.getenv("FUNDING_THRESHOLD_PCT", 0.0005))
    FUNDING_MIN_NET_RETURN = float(os.getenv("FUNDING_MIN_NET_RETURN", 0.001))
    FUNDING_POSITION_PCT = 0.5
    FUNDING_COOLDOWN_SECONDS = 300

    MAX_DAILY_LOSS_PCT = float(os.getenv("MAX_DAILY_LOSS_PCT", 0.15))
    MAX_CONSECUTIVE_LOSSES = int(os.getenv("MAX_CONSECUTIVE_LOSSES", 5))
    INITIAL_CAPITAL = float(os.getenv("INITIAL_CAPITAL", 100.0))

    BACKTEST_DEFAULT_DAYS = int(os.getenv("BACKTEST_DEFAULT_DAYS", 15))
    MONTE_CARLO_SIMULATIONS = int(os.getenv("MONTE_CARLO_SIMULATIONS", 1000))

    DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///trades.db")

config = Config()
EOF

# ============================================
# database.py
# ============================================
cat > database.py << 'EOF'
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from config import config

engine = create_engine(config.DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
EOF

# ============================================
# models.py
# ============================================
cat > models.py << 'EOF'
from sqlalchemy import Column, Integer, String, Float, DateTime, Boolean
from sqlalchemy.ext.declarative import declarative_base
from datetime import datetime

Base = declarative_base()

class Trade(Base):
    __tablename__ = "trades"
    id = Column(Integer, primary_key=True)
    symbol = Column(String)
    strategy = Column(String)   # 'wick' o 'funding'
    side = Column(String)
    entry_price = Column(Float)
    exit_price = Column(Float, nullable=True)
    quantity = Column(Float)
    pnl = Column(Float, default=0.0)
    status = Column(String, default="open")  # open, closed
    entry_time = Column(DateTime, default=datetime.utcnow)
    exit_time = Column(DateTime, nullable=True)
    exit_reason = Column(String, nullable=True)

class BotStatus(Base):
    __tablename__ = "bot_status"
    id = Column(Integer, primary_key=True)
    timestamp = Column(DateTime, default=datetime.utcnow)
    equity = Column(Float)
    daily_pnl = Column(Float)
    open_positions = Column(Integer)
    is_active = Column(Boolean, default=True)
EOF

# ============================================
# core/risk_manager.py
# ============================================
cat > core/risk_manager.py << 'EOF'
from datetime import date
from config import config

class RiskManager:
    def __init__(self):
        self.start_balance = config.INITIAL_CAPITAL
        self.daily_pnl = 0.0
        self.consecutive_losses = 0
        self.last_reset_date = date.today()
        self.kill_switch = False

    def check_daily_reset(self):
        today = date.today()
        if today != self.last_reset_date:
            self.daily_pnl = 0.0
            self.last_reset_date = today

    def update_pnl(self, pnl: float):
        self.check_daily_reset()
        self.daily_pnl += pnl
        if pnl < 0:
            self.consecutive_losses += 1
        else:
            self.consecutive_losses = 0

        if self.daily_pnl < -self.start_balance * config.MAX_DAILY_LOSS_PCT:
            self.kill_switch = True
        if self.consecutive_losses >= config.MAX_CONSECUTIVE_LOSSES:
            self.kill_switch = True
        return not self.kill_switch
EOF

# ============================================
# core/bybit_client.py
# ============================================
cat > core/bybit_client.py << 'BCT'
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
BCT

# ============================================
# core/wick_hunter.py
# ============================================
cat > core/wick_hunter.py << 'WICK'
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
WICK

# ============================================
# core/funding_vampire.py
# ============================================
cat > core/funding_vampire.py << 'FUND'
import time, logging
from datetime import datetime, timedelta
from config import config

logger = logging.getLogger("FundingVampire")

class FundingVampire:
    def __init__(self, client, risk_mgr):
        self.client = client
        self.risk = risk_mgr
        self.active_arbitrages = {}

    def scan_opportunities(self):
        opps = []
        for sym in config.FUNDING_SYMBOLS:
            try:
                ticker = self.client.http.get_tickers(category="linear", symbol=sym)
                rate = float(ticker["result"]["list"][0]["fundingRate"])
                if rate < config.FUNDING_THRESHOLD_PCT:
                    continue
                spot = self.client.http.get_tickers(category="spot", symbol=sym)
                perp = self.client.http.get_tickers(category="linear", symbol=sym)
                sp = float(spot["result"]["list"][0]["lastPrice"])
                pp = float(perp["result"]["list"][0]["lastPrice"])
                spread = abs(pp - sp) / sp
                net = rate - 0.0011 - spread  # ~0.055% comisión x2
                if net > config.FUNDING_MIN_NET_RETURN:
                    opps.append({"symbol": sym, "rate": rate, "net": net, "spot": sp, "perp": pp})
            except:
                pass
        return sorted(opps, key=lambda x: x["net"], reverse=True)

    def open_arbitrage(self, opp):
        sym = opp["symbol"]
        half = self.client.get_perp_balance() * config.FUNDING_POSITION_PCT / 2
        qty_spot = half / opp["spot"]
        qty_perp = half / opp["perp"]
        # spot buy
        r = self.client.place_market_order(sym, "Buy", qty_spot, "spot")
        if not r:
            return False
        # perp sell
        self.client.set_leverage(sym, 1)
        r2 = self.client.place_market_order(sym, "Sell", qty_perp, "linear")
        if not r2:
            self.client.place_market_order(sym, "Sell", qty_spot, "spot")
            return False
        self.active_arbitrages[sym] = {
            "spot_qty": qty_spot,
            "perp_qty": qty_perp,
            "entry_time": datetime.now(),
        }
        logger.info(f"🧛 ARBITRAGE {sym}: neto est. {opp['net']*100:.3f}%")
        return True

    def close_arbitrage(self, sym):
        arb = self.active_arbitrages.pop(sym, None)
        if not arb:
            return
        self.client.place_market_order(sym, "Sell", arb["spot_qty"], "spot")
        self.client.place_market_order(sym, "Buy", arb["perp_qty"], "linear")
        logger.info(f"🧛 Cerrado {sym}")

    def manage_arbitrages(self):
        to_close = []
        for sym, arb in self.active_arbitrages.items():
            try:
                ticker = self.client.http.get_tickers(category="linear", symbol=sym)
                rate = float(ticker["result"]["list"][0]["fundingRate"])
            except:
                rate = 0
            if rate < config.FUNDING_THRESHOLD_PCT / 2:
                to_close.append(sym)
            elif (datetime.now() - arb["entry_time"]).total_seconds() > 8*3600:
                to_close.append(sym)
        for s in to_close:
            self.close_arbitrage(s)

    def run(self):
        while True:
            if self.risk.kill_switch or config.STRATEGY_MODE == "WICK_ONLY":
                time.sleep(1)
                continue
            self.manage_arbitrages()
            if len(self.active_arbitrages) < 3:
                opps = self.scan_opportunities()
                for opp in opps[:1]:
                    if opp["symbol"] not in self.active_arbitrages:
                        self.open_arbitrage(opp)
            time.sleep(30)
FUND

# ============================================
# main.py
# ============================================
cat > main.py << 'MAIN'
import threading, time, logging
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session
from config import config
from database import engine, SessionLocal
from models import Base, Trade, BotStatus
from core.risk_manager import RiskManager
from core.bybit_client import BybitClient
from core.wick_hunter import WickHunter
from core.funding_vampire import FundingVampire

logging.basicConfig(level=logging.INFO, format='%(asctime)s | %(levelname)-7s | %(name)s | %(message)s')
logger = logging.getLogger("Main")

app = FastAPI(title="ULTIMATE SHADOW BOT CORE")
app.mount("/static", StaticFiles(directory="static"), name="static")

Base.metadata.create_all(bind=engine)

risk_mgr = RiskManager()
client = BybitClient(config)
wick_hunter = WickHunter(client, risk_mgr)
funding_vampire = FundingVampire(client, risk_mgr)

def log_trade(symbol, strategy, side, quantity, entry_price, status="open", pnl=0.0):
    db = SessionLocal()
    t = Trade(symbol=symbol, strategy=strategy, side=side, entry_price=entry_price, quantity=quantity, status=status, pnl=pnl)
    db.add(t)
    db.commit()
    db.close()

def update_status():
    while True:
        db = SessionLocal()
        try:
            bal = client.get_perp_balance()
            status = BotStatus(equity=bal, daily_pnl=risk_mgr.daily_pnl,
                                open_positions=len(wick_hunter.active_positions)+len(funding_vampire.active_arbitrages),
                                is_active=not risk_mgr.kill_switch)
            db.add(status)
            db.commit()
        except:
            pass
        finally:
            db.close()
        time.sleep(15)

@app.on_event("startup")
async def startup():
    threading.Thread(target=client.start_trade_stream, args=(config.WICK_SYMBOLS,), daemon=True).start()
    threading.Thread(target=wick_hunter.run, daemon=True).start()
    threading.Thread(target=funding_vampire.run, daemon=True).start()
    threading.Thread(target=update_status, daemon=True).start()

@app.get("/", response_class=HTMLResponse)
async def dashboard():
    with open("static/dashboard.html", "r") as f:
        return f.read()

@app.get("/api/status")
def get_status():
    db = SessionLocal()
    latest = db.query(BotStatus).order_by(BotStatus.timestamp.desc()).first()
    db.close()
    if latest:
        return {"equity": latest.equity, "daily_pnl": latest.daily_pnl, "open_positions": latest.open_positions,
                "is_active": latest.is_active, "kill_switch": risk_mgr.kill_switch}
    return {"equity": config.INITIAL_CAPITAL, "daily_pnl": 0, "open_positions": 0, "is_active": True, "kill_switch": False}

@app.get("/api/trades")
def get_trades(limit: int = 50):
    db = SessionLocal()
    trades = db.query(Trade).order_by(Trade.entry_time.desc()).limit(limit).all()
    db.close()
    return [{"id": t.id, "symbol": t.symbol, "strategy": t.strategy, "side": t.side,
             "entry_price": t.entry_price, "exit_price": t.exit_price, "quantity": t.quantity,
             "pnl": t.pnl, "status": t.status, "entry_time": t.entry_time.isoformat(),
             "exit_reason": t.exit_reason} for t in trades]

@app.get("/api/equity_history")
def equity_history(hours: int = 6):
    from datetime import datetime, timedelta
    since = datetime.utcnow() - timedelta(hours=hours)
    db = SessionLocal()
    rows = db.query(BotStatus).filter(BotStatus.timestamp >= since).order_by(BotStatus.timestamp).all()
    db.close()
    return [{"t": r.timestamp.isoformat(), "equity": r.equity} for r in rows]

@app.get("/health")
def health():
    return {"status": "ok", "mode": config.STRATEGY_MODE}
MAIN

# ============================================
# static/dashboard.html (mismo código que antes)
# ============================================
cat > static/dashboard.html << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>ULTIMATE SHADOW BOT CORE</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: 'Courier New', monospace; background: #0a0a0a; color: #00ff88; margin: 20px; }
        .card { background: #1a1a1a; border: 1px solid #00ff88; padding: 15px; margin-bottom: 15px; border-radius: 8px; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { border: 1px solid #00ff88; padding: 6px; text-align: left; }
        .profit { color: #00ff00; }
        .loss { color: #ff3333; }
    </style>
</head>
<body>
    <h1>⚡ ULTIMATE SHADOW BOT CORE</h1>
    <div class="card">
        <h2>Estado</h2>
        <p>Equity: $<span id="equity">0</span> | P&L diario: $<span id="pnl">0</span> | Posiciones: <span id="positions">0</span></p>
        <p>Kill Switch: <span id="kill">-</span></p>
    </div>
    <div class="card">
        <canvas id="equityChart" height="100"></canvas>
    </div>
    <div class="card">
        <h2>Últimos trades</h2>
        <table id="tradesTable">
            <tr><th>Hora</th><th>Símbolo</th><th>Estrategia</th><th>Lado</th><th>P&L</th><th>Estado</th></tr>
        </table>
    </div>
    <script>
        async function fetchStatus() {
            const res = await fetch('/api/status');
            const data = await res.json();
            document.getElementById('equity').textContent = data.equity.toFixed(2);
            document.getElementById('pnl').textContent = data.daily_pnl.toFixed(2);
            document.getElementById('positions').textContent = data.open_positions;
            document.getElementById('kill').textContent = data.kill_switch ? 'ACTIVO' : 'Normal';
        }
        async function fetchTrades() {
            const res = await fetch('/api/trades?limit=20');
            const trades = await res.json();
            const table = document.getElementById('tradesTable');
            table.innerHTML = '<tr><th>Hora</th><th>Símbolo</th><th>Estrategia</th><th>Lado</th><th>P&L</th><th>Estado</th></tr>';
            trades.forEach(t => {
                const pnlClass = t.pnl >= 0 ? 'profit' : 'loss';
                table.insertAdjacentHTML('beforeend', 
                    `<tr><td>${new Date(t.entry_time).toLocaleTimeString()}</td><td>${t.symbol}</td><td>${t.strategy}</td><td>${t.side}</td><td class="${pnlClass}">${t.pnl.toFixed(4)}</td><td>${t.status}</td></tr>`
                );
            });
        }
        async function fetchEquityHistory() {
            const res = await fetch('/api/equity_history?hours=6');
            const data = await res.json();
            return { labels: data.map(d => new Date(d.t).toLocaleTimeString()), values: data.map(d => d.equity) };
        }
        async function updateChart() {
            const { labels, values } = await fetchEquityHistory();
            if (window.myChart) {
                window.myChart.data.labels = labels;
                window.myChart.data.datasets[0].data = values;
                window.myChart.update();
            }
        }
        window.onload = async () => {
            const ctx = document.getElementById('equityChart').getContext('2d');
            const init = await fetchEquityHistory();
            window.myChart = new Chart(ctx, {
                type: 'line',
                data: { labels: init.labels, datasets: [{ label: 'Equity ($)', data: init.values, borderColor: '#00ff88', backgroundColor: 'rgba(0,255,136,0.1)', fill: true, tension: 0.3 }] },
                options: { responsive: true, scales: { x: { display: false }, y: { beginAtZero: false } } }
            });
            setInterval(() => { fetchStatus(); fetchTrades(); updateChart(); }, 5000);
            fetchStatus(); fetchTrades();
        };
    </script>
</body>
</html>
HTML

echo ""
echo "✅ Proyecto generado correctamente."
echo ""
echo "AHORA SIGUE ESTOS PASOS:"
echo "1. cp .env.example .env"
echo "2. Edita .env con tus API keys de Bybit (testnet recomendado)"
echo "3. python3 -m venv venv && source venv/bin/activate"
echo "4. pip install -r requirements.txt"
echo "5. uvicorn main:app --host 0.0.0.0 --port 8000"
echo "6. Abre http://TU_IP:8000"
