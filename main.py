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
