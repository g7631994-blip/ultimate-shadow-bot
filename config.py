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
