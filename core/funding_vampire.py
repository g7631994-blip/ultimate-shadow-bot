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
