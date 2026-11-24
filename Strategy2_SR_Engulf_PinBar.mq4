#property strict
#property description "Swing breakout retest engulfing EA"
input int MagicNumber=260202; // 订单识别号：区分本EA与其他EA的订单
input ENUM_TIMEFRAMES SignalTimeframe=PERIOD_H1; // 信号周期：波段、突破、形态和ATR均采用此周期
input int RetestMaxBars=50; // 突破后等待回踩或反弹的最大K线根数
input int LookbackBars=100; // 向历史搜索最近波段高低点的范围
input int SwingLeftBars=2; // 波段点左侧（更早）的确认K线根数
input int SwingRightBars=2; // 波段点右侧（更近）的确认K线根数
input int ATRPeriod=14; // ATR波动率计算周期
input double LevelToleranceATR=0.25; // 回踩位置允许偏差，单位为ATR倍数
input double StopATR=2.0; // 止损距离，单位为ATR倍数
input double TargetATR=2.0; // 止盈距离，单位为ATR倍数
input double InitialRiskPercent=1.0; // 初始止损风险占账户净值的百分比，并非保证金比例
input int MaxDoublings=5; // 连续亏损后最多翻倍次数
input double MaxRiskPercent=32.0; // 翻倍后的单笔风险百分比上限
input double PinWickBodyRatio=2.0; // Pin Bar主影线与实体的最小比例
input double PinCloseFraction=0.35; // Pin Bar收盘所在顶部或底部区域比例
input int MaxSpreadPoints=50; // 允许的最大点差，单位为报价点（point）
input int SlippagePoints=20; // 允许的下单滑点，单位为报价点（point）
// 保存当前周期的新柱时间；等待突破状态仅保存在内存中，重载后清空。
datetime lastBar=0;
double flippedSupport=0, flippedResistance=0;
int supportAge=0, resistanceAge=0;

// 初始化：检查参数，并跳过启动时已经形成的信号。
int OnInit()
{
 if(RetestMaxBars<1 || SwingLeftBars<1 || SwingRightBars<1 || LookbackBars<SwingRightBars+2 || ATRPeriod<1 || LevelToleranceATR<0 || StopATR<=0 || TargetATR<=0 || InitialRiskPercent<=0 || MaxRiskPercent<InitialRiskPercent || MaxRiskPercent>100 || MaxDoublings<0 || MaxDoublings>20 || PinWickBodyRatio<=0 || PinCloseFraction<=0 || PinCloseFraction>=0.5 || MaxSpreadPoints<0 || SlippagePoints<0) return(INIT_PARAMETERS_INCORRECT);
 lastBar=iTime(Symbol(),SignalTimeframe,0);
 return(INIT_SUCCEEDED);
}

// 查找最近已确认的波段点：highPoint为真查高点，否则查低点。
// 索引0为未收盘柱，1为信号柱；右侧确认最晚到索引2，不使用未来数据。
// 从近到远搜索，要求高点严格更高、低点严格更低，相同价格不算波段点。
bool FindSwingLevel(bool highPoint,double &level)
{
 for(int shift=SwingRightBars+2;shift<=LookbackBars+1;shift++)
 {
  double price=highPoint?iHigh(Symbol(),SignalTimeframe,shift):iLow(Symbol(),SignalTimeframe,shift);
  bool valid=true;
  for(int left=1;left<=SwingLeftBars;left++)
  {
   double other=highPoint?iHigh(Symbol(),SignalTimeframe,shift+left):iLow(Symbol(),SignalTimeframe,shift+left);
   if((highPoint && price<=other) || (!highPoint && price>=other)) { valid=false; break; }
  }
  if(!valid) continue;
  for(int right=1;right<=SwingRightBars;right++)
  {
   double other=highPoint?iHigh(Symbol(),SignalTimeframe,shift-right):iLow(Symbol(),SignalTimeframe,shift-right);
   if((highPoint && price<=other) || (!highPoint && price>=other)) { valid=false; break; }
  }
  if(valid) { level=price; return(true); }
 }
 return(false);
}

// 检查当前品种与本EA识别号的活动订单（含挂单），避免重复开仓。
bool HasPosition()
{
 for(int i=OrdersTotal()-1;i>=0;i--)
  if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES) && OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber) return(true);
 return(false);
}

// 按平仓时间、订单号从近到远统计连续亏损，不能依赖历史列表的排列顺序。
// 净利润包含佣金和隔夜费；盈利或保本即终止亏损序列。
int LossStreak()
{
 int streak=0; datetime beforeTime=2147483647; int beforeTicket=2147483647;
 for(int n=0;n<MaxDoublings;n++)
 {
  datetime newest=0; int ticket=-1; double profit=0;
  for(int i=OrdersHistoryTotal()-1;i>=0;i--)
  {
   if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
   if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber || OrderType()>OP_SELL) continue;
   datetime t=OrderCloseTime(); int id=OrderTicket();
   if(t>beforeTime || (t==beforeTime && id>=beforeTicket)) continue;
   if(t>newest || (t==newest && id>ticket)) { newest=t; ticket=id; profit=OrderProfit()+OrderSwap()+OrderCommission(); }
  }
  if(ticket<0 || profit>=0) break;
  streak++; beforeTime=newest; beforeTicket=ticket;
 }
 return(streak);
}

// 根据止损价格距离及每跳价值计算手数，风险基于当前账户净值。
double LotsForRisk(double distance)
{
 double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE), tickValue=MarketInfo(Symbol(),MODE_TICKVALUE);
 double step=MarketInfo(Symbol(),MODE_LOTSTEP), minimum=MarketInfo(Symbol(),MODE_MINLOT);
 if(tickSize<=0 || tickValue<=0 || step<=0) return(0);
 // 每连续亏损一次风险翻倍，同时受次数上限和风险百分比上限限制。
 double risk=MathMin(MaxRiskPercent,InitialRiskPercent*MathPow(2,LossStreak()));
 double lots=AccountEquity()*risk/100.0/(distance/tickSize*tickValue);
 // 按经纪商手数步长向下取整，并限制到最大允许手数。
 lots=MathFloor(MathMin(lots,MarketInfo(Symbol(),MODE_MAXLOT))/step+1e-8)*step;
 if(lots<minimum) return(0); // 低于最小手数时跳过，不向上取整扩大风险。
 return(NormalizeDouble(lots,8));
}

// 主流程：每根新柱仅检查一次上一根已收盘K线。
void OnTick()
{
 datetime bar=iTime(Symbol(),SignalTimeframe,0);
 if(bar==0 || bar==lastBar) return;
 lastBar=bar;
 if(iBars(Symbol(),SignalTimeframe)<LookbackBars+SwingLeftBars+ATRPeriod+5) return;
 double atr=iATR(Symbol(),SignalTimeframe,ATRPeriod,1);
 if(atr<=0) return;
 double support=0, resistance=0;
 bool hasSupport=FindSwingLevel(false,support);
 bool hasResistance=FindSwingLevel(true,resistance);
 // o/c/h/l为信号柱开收高低价，po/pc为前一根柱的开收价。
 double o=iOpen(Symbol(),SignalTimeframe,1), c=iClose(Symbol(),SignalTimeframe,1);
 double h=iHigh(Symbol(),SignalTimeframe,1), l=iLow(Symbol(),SignalTimeframe,1);
 double po=iOpen(Symbol(),SignalTimeframe,2), pc=iClose(Symbol(),SignalTimeframe,2);
 // 原阻力转支撑、原支撑转阻力后，超时或收盘穿回错误一侧即失效。
 if(flippedSupport>0 && (++supportAge>RetestMaxBars || c<flippedSupport)) flippedSupport=0;
 if(flippedResistance>0 && (++resistanceAge>RetestMaxBars || c>flippedResistance)) flippedResistance=0;
 // 实体吞没：前柱方向相反，当前实体完整覆盖前实体，至少一端严格超出。
 bool bullEngulf=c>o && pc<po && o<=pc && c>=po && (o<pc || c>po);
 bool bearEngulf=c<o && pc>po && o>=pc && c<=po && (o>pc || c<po);
 // Pin Bar：主影线足够长、另一侧影线不大于实体，收盘靠近对应端点。
 // 十字星按至少一个报价点的实体计算，不限制实体颜色。
 double body=MathMax(MathAbs(c-o),Point), range=h-l;
 double lower=MathMin(o,c)-l, upper=h-MathMax(o,c);
 bool bullPin=range>0 && lower>=PinWickBodyRatio*body && upper<=body && c>=h-range*PinCloseFraction;
 bool bearPin=range>0 && upper>=PinWickBodyRatio*body && lower<=body && c<=l+range*PinCloseFraction;
 // 信号柱触及互换位置附近且收盘站在正确一侧，吞没或Pin Bar任一成立即可。
 double tolerance=atr*LevelToleranceATR;
 bool buy=flippedSupport>0 && MathAbs(l-flippedSupport)<=tolerance && c>flippedSupport && (bullEngulf || bullPin);
 bool sell=flippedResistance>0 && MathAbs(h-flippedResistance)<=tolerance && c<flippedResistance && (bearEngulf || bearPin);
 // 收盘价穿越最近确认波段点才认定突破；新突破替换同方向等待位置。
 // 突破当根不按新位置开仓，等待后续回踩或反弹信号。
 if(hasResistance && pc<=resistance && c>resistance)
 { flippedSupport=resistance; supportAge=0; buy=false; }
 if(hasSupport && pc>=support && c<support)
 { flippedResistance=support; resistanceAge=0; sell=false; }
 // 持仓时仍更新突破状态，但不再开新仓。
 if(HasPosition()) return;
 RefreshRates();
 if(MarketInfo(Symbol(),MODE_SPREAD)>MaxSpreadPoints) return;
 // 无信号或多空同时成立时跳过。
 if(buy==sell) return;
 int type=buy?OP_BUY:OP_SELL;
 double entry=buy?Ask:Bid;
 // 买入按Ask、卖出按Bid入场；按信号柱ATR设置固定止损止盈。
 double sl=NormalizeDouble(entry+(buy?-1:1)*StopATR*atr,Digits);
 double tp=NormalizeDouble(entry+(buy?1:-1)*TargetATR*atr,Digits);
 // 检查经纪商最小止损距离；不符合则跳过，不自动扩大止损。
 double minDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
 if((buy && (Bid-sl<minDistance || tp-Bid<minDistance)) || (!buy && (sl-Ask<minDistance || Ask-tp<minDistance))) { Print("Skipped: broker stop distance constraint"); return; }
 double lots=LotsForRisk(MathAbs(entry-sl));
 if(lots<=0) { Print("Skipped: invalid sizing or below minimum lot"); return; }
 // 下单前检查保证金；失败只记录日志，本根K线不重试。
 ResetLastError();
 if(AccountFreeMarginCheck(Symbol(),type,lots)<=0 || GetLastError()==134) { Print("Skipped: insufficient margin"); return; }
 int ticket=OrderSend(Symbol(),type,lots,entry,SlippagePoints,sl,tp,"Strategy2 retest",MagicNumber,0,buy?clrBlue:clrRed);
 if(ticket<0) Print("OrderSend failed: ",GetLastError());
 // 成功后清除对应等待位置，每次突破最多成功开仓一次。
 else { if(buy) flippedSupport=0; else flippedResistance=0; }
}
