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
