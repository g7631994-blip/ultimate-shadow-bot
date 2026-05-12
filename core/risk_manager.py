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
