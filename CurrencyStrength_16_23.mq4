#property strict
#property version "1.00"
#property description "USD-relative currency strength; Beijing 16:00 / 23:00; risk-based recovery sizing."

input int    MagicNumber            = 1623001;
input string SymbolPrefix           = ""; // 留空时自动识别；手动设置优先。
input string SymbolSuffix           = ""; // 支持自动识别m、.pro等后缀。
input double InitialRiskPercent     = 1.0;
input double LossMultiplier         = 2.0;
input double SignalThresholdPercent = 0.2;
input double StopLossPercent        = 0.2;
input double TakeProfitPercent      = 0.2;
input int    EntryWindowSeconds     = 60; // 仅在每个预定开仓时间后的第一分钟内检查。
input bool   AutoServerUTCOffset    = true;
input double ManualServerUTCOffset  = 2.0; // 经纪商服务器相对UTC的小时偏移；切换夏令时后需更新。
input int    MaxQuoteAgeSeconds     = 30;
input int    SlippagePoints         = 20;
input double MaxRiskPercent         = 0.0; // 0表示不额外限制风险；超限时跳过开仓，不缩减风险金额。

string currencies[8] = {"USD","EUR","GBP","JPY","CHF","CAD","AUD","NZD"};
string usdPairs[7] = {"EURUSD","GBPUSD","AUDUSD","NZDUSD","USDJPY","USDCHF","USDCAD"};
string keyRoot;
string detectedPrefix="",detectedSuffix="";
bool chartNamingDetected=false;
bool busy=false;
datetime lastNote=0;

string Key(string suffix) { return keyRoot+suffix; }
double ReadGV(string suffix,double fallback=0.0)
{
   string key=Key(suffix);
   if(GlobalVariableCheck(key)) return GlobalVariableGet(key);
   return fallback;
}
void SaveGV(string suffix,double value) { GlobalVariableSet(Key(suffix),value); }
void Note(string text)
{
   if(TimeCurrent()-lastNote>=10 || lastNote==0)
   { Print(text); lastNote=TimeCurrent(); }
}

int ServerOffsetSeconds()
{
   if(!AutoServerUTCOffset) return (int)MathRound(ManualServerUTCOffset*3600.0);
   return (int)(MathRound((double)(TimeCurrent()-TimeGMT())/900.0)*900.0);
}
datetime BeijingNow() { return TimeCurrent()-ServerOffsetSeconds()+8*3600; }
int DateKey(datetime value)
{
   return TimeYear(value)*10000+TimeMonth(value)*100+TimeDay(value);
}

bool Lock()
{
   string name=Key("lock");
   if(!GlobalVariableCheck(name)) GlobalVariableSet(name,0);
   double old=GlobalVariableGet(name);
   if(old>TimeLocal()) return false;
   return GlobalVariableSetOnCondition(name,(double)TimeLocal()+60.0,old);
}
void Unlock() { GlobalVariableSet(Key("lock"),0); }

bool Ours()
{
   return OrderMagicNumber()==MagicNumber && (OrderType()==OP_BUY || OrderType()==OP_SELL);
}
bool AnyExposure()
{
   // 包括本账户的手工单、其他EA订单及挂单。
   return OrdersTotal()>0;
}

void DetectSymbolNaming()
{
   detectedPrefix=""; detectedSuffix=""; chartNamingDetected=false;
   if(SymbolPrefix!="" || SymbolSuffix!="") return;
   string chart=Symbol();
   int matches=0;
   for(int i=0;i<8;i++)
   {
      for(int j=0;j<8;j++)
      {
         if(i==j) continue;
         string pair=currencies[i]+currencies[j];
         int pos=StringFind(chart,pair);
         if(pos<0) continue;
         matches++;
         detectedPrefix=StringSubstr(chart,0,pos);
         detectedSuffix=StringSubstr(chart,pos+6);
      }
   }
   chartNamingDetected=(matches==1);
   if(!chartNamingDetected) { detectedPrefix=""; detectedSuffix=""; }
   else Print("自动识别品种命名：前缀=[",detectedPrefix,"]，后缀=[",detectedSuffix,"]，来源图表=",chart);
}

bool SelectBrokerSymbol(string symbol)
{
   return SymbolSelect(symbol,true) && MarketInfo(symbol,MODE_POINT)>0;
}

string BrokerSymbol(string base)
{
   string exact=SymbolPrefix+base+SymbolSuffix;
   // 明确设置品种前缀或后缀后，不自动改选其他合约。
   if(SymbolPrefix!="" || SymbolSuffix!="")
      return SelectBrokerSymbol(exact) ? exact : "";
   // 优先沿用当前外汇图表的命名，避免USDJPY和USDJPYm同时存在时选错。
   if(chartNamingDetected)
   {
      exact=detectedPrefix+base+detectedSuffix;
      return SelectBrokerSymbol(exact) ? exact : "";
   }
   // 非上述八种货币的图表无法推断命名，改为扫描全部可用合约。
   string candidate="";
   for(int i=0;i<SymbolsTotal(false);i++)
   {
      string s=SymbolName(i,false);
      if(StringFind(s,base)<0 || MarketInfo(s,MODE_POINT)<=0) continue;
      if(candidate!="") return ""; // 存在多个候选品种，请明确设置前缀或后缀。
      candidate=s;
   }
   if(candidate!="" && SelectBrokerSymbol(candidate)) return candidate;
   return "";
}

bool Quote(string symbol,double &bid,double &ask)
{
   bid=MarketInfo(symbol,MODE_BID); ask=MarketInfo(symbol,MODE_ASK);
   datetime tick=(datetime)MarketInfo(symbol,MODE_TIME);
   return bid>0 && ask>=bid && tick>0 &&
          MathAbs((double)(TimeCurrent()-tick))<=MaxQuoteAgeSeconds;
}

bool PickTrade(string &symbol,int &type,double &change)
{
   double ratio[8]; ArrayInitialize(ratio,0); ratio[0]=1.0;
   datetime commonDailyStart=0;
   for(int i=0;i<7;i++)
   {
      string s=BrokerSymbol(usdPairs[i]);
      if(s=="") { Note("Missing or ambiguous USD pair: "+usdPairs[i]); return false; }
      double bid,ask;
      if(!Quote(s,bid,ask)) { Note("Stale quote: "+s); return false; }
      datetime dailyStart=iTime(s,PERIOD_D1,0);
      double open=iOpen(s,PERIOD_D1,0);
      if(dailyStart<=0 || open<=0 || TimeCurrent()<dailyStart ||
         TimeCurrent()-dailyStart>=26*3600)
      { Note("D1 history not ready: "+s); return false; }
      if(commonDailyStart==0) commonDailyStart=dailyStart;
      if(commonDailyStart!=dailyStart)
      { Note("USD pairs have inconsistent D1 session starts."); return false; }
      string c;
      double r;
      if(StringSubstr(usdPairs[i],3,3)=="USD")
      { c=StringSubstr(usdPairs[i],0,3); r=bid/open; }
      else { c=StringSubstr(usdPairs[i],3,3); r=open/bid; }
      for(int j=1;j<8;j++) if(currencies[j]==c) ratio[j]=r;
   }
   int strongest=0,weakest=0;
   for(int k=0;k<8;k++)
   {
      if(ratio[k]<=0) return false;
      if(ratio[k]>ratio[strongest]) strongest=k;
      if(ratio[k]<ratio[weakest]) weakest=k;
   }
   change=(ratio[strongest]/ratio[weakest]-1.0)*100.0;
   if(change<=SignalThresholdPercent) return false;
   string strong=currencies[strongest],weak=currencies[weakest];
   symbol=BrokerSymbol(strong+weak); type=OP_BUY;
   if(symbol=="") { symbol=BrokerSymbol(weak+strong); type=OP_SELL; }
   if(symbol=="") { Note("Missing/ambiguous cross: "+strong+"/"+weak); return false; }
   return true;
}

double TickSizePrice(string symbol)
{
   double size=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   return size;
}
double RiskPerLot(string symbol,double entry,double stop)
{
   double size=TickSizePrice(symbol),value=MarketInfo(symbol,MODE_TICKVALUE);
   if(size<=0 || value<=0) return 0;
   return MathAbs(entry-stop)/size*value;
}

// 重启后查找最近订单，也涵盖下单成功但尚未保存状态的情况。
int LatestTicket()
{
   int ticket=(int)ReadGV("lastTicket",0);
   datetime latest=0;
   if(ticket>0)
   {
      if(!OrderSelect(ticket,SELECT_BY_TICKET)) return -1;
      if(!Ours()) return -1;
      latest=OrderOpenTime();
   }
   for(int pool=0;pool<2;pool++)
   {
      int total=(pool==0 ? OrdersTotal() : OrdersHistoryTotal());
      for(int i=0;i<total;i++)
      {
         if(!OrderSelect(i,SELECT_BY_POS,pool==0 ? MODE_TRADES : MODE_HISTORY)) continue;
         if(!Ours()) continue;
         if(OrderOpenTime()>latest || (OrderOpenTime()==latest && OrderTicket()>ticket))
         { latest=OrderOpenTime(); ticket=OrderTicket(); }
      }
   }
   return ticket;
}

bool NextRisk(double &risk)
{
   risk=AccountEquity()*InitialRiskPercent/100.0;
   int ticket=LatestTicket();
   if(ticket<0) { Note("Cannot load last EA order. Load full account history."); return false; }
   if(ticket==0) return risk>0;
   SaveGV("lastTicket",ticket);
   if(!OrderSelect(ticket,SELECT_BY_TICKET) || !Ours()) return false;
   if(OrderCloseTime()==0) return false;
   double net=OrderProfit()+OrderSwap()+OrderCommission();
   if(net>0) return risk>0; // 盈利后将风险预算恢复为当前净值乘以初始风险比例（默认1%）。
   double previousRisk=ReadGV("risk."+IntegerToString(ticket),0);
   if(previousRisk<=0)
   {
      // 本EA使用固定止损；状态保存中断或丢失时，根据订单止损重建风险金额。
      double stop=OrderStopLoss();
      if(stop<=0) { Note("Last order has no SL; risk recovery is unavailable."); return false; }
      previousRisk=RiskPerLot(OrderSymbol(),OrderOpenPrice(),stop)*OrderLots();
      if(previousRisk<=0) return false;
      SaveGV("risk."+IntegerToString(ticket),previousRisk);
   }
   risk=previousRisk*(net<0 ? LossMultiplier : 1.0); // 净收益为零时保持上一笔风险金额。
   return risk>0;
}

int EntriesToday(int date)
{
   int count=0;
   int offset=ServerOffsetSeconds();
   for(int pool=0;pool<2;pool++)
   {
      int total=(pool==0 ? OrdersTotal() : OrdersHistoryTotal());
      for(int i=0;i<total;i++)
      {
         if(!OrderSelect(i,SELECT_BY_POS,pool==0 ? MODE_TRADES : MODE_HISTORY)) continue;
         if(Ours() && DateKey(OrderOpenTime()-offset+8*3600)==date) count++;
      }
   }
   return (int)MathMax(count,ReadGV("count."+IntegerToString(date),0));
}

void CheckEntry()
{
   if(AnyExposure()) return;
   datetime bj=BeijingNow();
   if(TimeDayOfWeek(bj)==0 || TimeDayOfWeek(bj)==6) return;
   int hour=TimeHour(bj);
   if(hour!=16 && hour!=23) return;
   int seconds=TimeMinute(bj)*60+TimeSeconds(bj);
   if(seconds>=EntryWindowSeconds) return;
   int date=DateKey(bj);
   string slot="slot."+IntegerToString(date)+"."+IntegerToString(hour);
   if(ReadGV(slot,0)>0) return;
   int count=EntriesToday(date);
   if(count>=2) return;
   if(!IsConnected() || !IsTradeAllowed() || IsTradeContextBusy()) return;

   double budget;
   if(!NextRisk(budget)) return;
   if(MaxRiskPercent>0 && budget>AccountEquity()*MaxRiskPercent/100.0)
   { Note("Next risk exceeds configured cap; entry skipped."); return; }
   string symbol; int type; double change;
   if(!PickTrade(symbol,type,change)) return;
   if(MarketInfo(symbol,MODE_TRADEALLOWED)==0) return;
   double bid,ask;
   if(!Quote(symbol,bid,ask)) return;
   double entry=(type==OP_BUY ? ask : bid);
   double sl=entry*(1.0+(type==OP_BUY ? -1.0 : 1.0)*StopLossPercent/100.0);
   double tp=entry*(1.0+(type==OP_BUY ? 1.0 : -1.0)*TakeProfitPercent/100.0);
   int digits=(int)MarketInfo(symbol,MODE_DIGITS);
   double tick=TickSizePrice(symbol);
   if(tick<=0) return;
   sl=NormalizeDouble(MathRound(sl/tick)*tick,digits);
   tp=NormalizeDouble(MathRound(tp/tick)*tick,digits);
   double minimum=MarketInfo(symbol,MODE_STOPLEVEL)*MarketInfo(symbol,MODE_POINT);
   if((type==OP_BUY && (bid-sl<minimum || tp-bid<minimum)) ||
      (type==OP_SELL && (sl-ask<minimum || ask-tp<minimum)))
   { Note("SL/TP is inside broker minimum stop distance; entry skipped."); return; }
   double perLot=RiskPerLot(symbol,entry,sl);
   double step=MarketInfo(symbol,MODE_LOTSTEP), minLot=MarketInfo(symbol,MODE_MINLOT);
   double maxLot=MarketInfo(symbol,MODE_MAXLOT);
   if(perLot<=0 || step<=0 || minLot<=0 || maxLot<=0) return;
   double rawLots=budget/perLot;
   if(rawLots>maxLot+0.00000001)
   { Note("Required volume exceeds broker maximum; entry skipped."); return; }
   double lots=NormalizeDouble(MathFloor((rawLots+1e-10)/step)*step,8);
   if(lots<minLot)
   { Note("Risk budget is below minimum lot size; entry skipped."); return; }
   ResetLastError();
   double free=AccountFreeMarginCheck(symbol,type,lots);
   if(free<=0 || GetLastError()!=0)
   { Note("Insufficient margin for required risk amount; entry skipped."); return; }
   if(AnyExposure()) return;
   // 发送订单前先保存本时段标记，避免超时或重启造成重复下单。
   // 下单失败也占用本时段的尝试机会，但不计入当日成功开仓次数。
   SaveGV(slot,1); GlobalVariablesFlush();
   int ticket=OrderSend(symbol,type,lots,entry,SlippagePoints,sl,tp,
                        "CS Beijing "+IntegerToString(hour),MagicNumber,0,clrNONE);
   if(ticket<0)
   {
      int err=GetLastError();
      Print("OrderSend failed: ",err,". This time slot will not be retried.");
      return;
   }
   double actualRisk=lots*perLot;
   if(OrderSelect(ticket,SELECT_BY_TICKET))
   {
      double measured=RiskPerLot(symbol,OrderOpenPrice(),OrderStopLoss())*OrderLots();
      if(measured>0) actualRisk=measured;
   }
   SaveGV("risk."+IntegerToString(ticket),actualRisk);
   SaveGV("lastTicket",ticket);
   SaveGV("count."+IntegerToString(date),count+1);
   GlobalVariablesFlush();
   Print("Opened #",ticket," ",symbol," lots=",DoubleToString(lots,4),
         " target risk=",DoubleToString(budget,2)," actual planned risk=",DoubleToString(actualRisk,2),
         " signal=",DoubleToString(change,4),"%");
}

void Process()
{
   if(busy) return;
   busy=true;
   if(Lock()) { CheckEntry(); Unlock(); }
   busy=false;
}
int OnInit()
{
   if(InitialRiskPercent<=0 || InitialRiskPercent>=100 || LossMultiplier<1 ||
      SignalThresholdPercent<0 || StopLossPercent<=0 || StopLossPercent>=100 ||
      TakeProfitPercent<=0 || EntryWindowSeconds<1 || EntryWindowSeconds>60 ||
      MaxQuoteAgeSeconds<1 || SlippagePoints<0 || MaxRiskPercent<0 || MagicNumber<=0)
      return INIT_PARAMETERS_INCORRECT;
   // MT4原生策略测试器无法完整执行多品种组合交易策略。
   if(IsTesting())
   { Print("Use a multi-currency-capable test environment/demo account; native MT4 tester is unsupported."); return INIT_FAILED; }
   keyRoot="CS1623."+IntegerToString(AccountNumber())+"."+IntegerToString(MagicNumber)+".";
   DetectSymbolNaming();
   if(!GlobalVariableCheck(Key("lock"))) GlobalVariableSet(Key("lock"),0);
   for(int i=0;i<7;i++)
   {
      string s=BrokerSymbol(usdPairs[i]);
      if(s=="") { Print("Configure symbol prefix/suffix; missing/ambiguous: ",usdPairs[i]); return INIT_FAILED; }
      double preload=iOpen(s,PERIOD_D1,0);
   }
   if(!EventSetTimer(1)) return INIT_FAILED;
   Print("EA ready. Beijing=",TimeToString(BeijingNow(),TIME_DATE|TIME_SECONDS),
         "; broker UTC offset=",DoubleToString(ServerOffsetSeconds()/3600.0,2),
         "; entries at 16:00 and 23:00 only; first-minute window.");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTick() { Process(); }
void OnTimer() { Process(); }
