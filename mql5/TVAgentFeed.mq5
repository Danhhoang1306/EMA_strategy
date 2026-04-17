//+------------------------------------------------------------------+
//| TVAgentFeed.mq5 - Push tick/bar data to Python via ZMQ           |
//|                                                                  |
//| Attach to any chart. Sends:                                      |
//|   - Every new tick (bid, ask, last, volume)                      |
//|   - Every new bar (OHLCV of completed bar)                       |
//|   - Indicator values (EMA, RSI, ATR)                             |
//|                                                                  |
//| Protocol: JSON over ZMQ PUSH socket (tcp://127.0.0.1:5555)      |
//+------------------------------------------------------------------+
#property copyright "TVAgentTeam"
#property version   "1.00"
#property strict

// ZMQ socket library - you need to install:
// https://github.com/dingmaotu/mql-zmq
#include <Zmq/Zmq.mqh>

//--- Input parameters
input string   ZmqAddress    = "tcp://127.0.0.1:5555";  // ZMQ address
input int      EMA_Fast      = 8;
input int      EMA_Mid       = 21;
input int      EMA_Slow      = 50;
input int      RSI_Period    = 14;
input int      ATR_Period    = 14;
input bool     SendTicks     = true;      // Send every tick
input bool     SendBars      = true;      // Send completed bars
input bool     SendIndicators = true;     // Send indicator values
input int      BarHistory    = 5;         // How many recent bars to send on new bar

//--- ZMQ
Context  context("TVAgentFeed");
Socket   sender(context, ZMQ_PUSH);

//--- State
datetime lastBarTime = 0;
int handleEmaFast, handleEmaMid, handleEmaSlow, handleRsi, handleAtr;

//+------------------------------------------------------------------+
int OnInit()
{
   // Connect ZMQ
   if(!sender.connect(ZmqAddress))
   {
      Print("ZMQ connect failed: ", ZmqAddress);
      return INIT_FAILED;
   }

   sender.setLinger(0);
   sender.setSendHighWaterMark(1000);

   Print("ZMQ connected: ", ZmqAddress, " | Symbol: ", _Symbol, " | TF: ", EnumToString(_Period));

   // Create indicator handles
   handleEmaFast = iMA(_Symbol, _Period, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEmaMid  = iMA(_Symbol, _Period, EMA_Mid,  0, MODE_EMA, PRICE_CLOSE);
   handleEmaSlow = iMA(_Symbol, _Period, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   handleRsi     = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
   handleAtr     = iATR(_Symbol, _Period, ATR_Period);

   // Send initial bar history
   if(SendBars)
      SendBarHistory(BarHistory);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   sender.disconnect(ZmqAddress);
   Print("ZMQ disconnected");
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Send tick data
   if(SendTicks)
      SendTickData();

   // Check for new bar
   if(SendBars)
   {
      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(currentBarTime != lastBarTime && lastBarTime != 0)
      {
         // New bar formed - send completed bar (index 1)
         SendNewBar();
      }
      lastBarTime = currentBarTime;
   }
}

//+------------------------------------------------------------------+
void SendTickData()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   string json = StringFormat(
      "{\"type\":\"tick\",\"symbol\":\"%s\",\"tf\":\"%s\","
      "\"bid\":%.5f,\"ask\":%.5f,\"last\":%.5f,\"volume\":%d,"
      "\"time\":%d,\"spread\":%.1f}",
      _Symbol, EnumToString(_Period),
      tick.bid, tick.ask, tick.last, (int)tick.volume,
      (int)tick.time,
      (tick.ask - tick.bid) / _Point
   );

   ZmqMsg msg(json);
   sender.send(msg, true);  // non-blocking
}

//+------------------------------------------------------------------+
void SendNewBar()
{
   // Get completed bar data (index 1 = last completed bar)
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 1, 1, rates) != 1)
      return;

   // Get indicator values
   double emaF[1], emaM[1], emaS[1], rsi[1], atr[1];
   string indJson = "";

   if(SendIndicators)
   {
      CopyBuffer(handleEmaFast, 0, 1, 1, emaF);
      CopyBuffer(handleEmaMid,  0, 1, 1, emaM);
      CopyBuffer(handleEmaSlow, 0, 1, 1, emaS);
      CopyBuffer(handleRsi,     0, 1, 1, rsi);
      CopyBuffer(handleAtr,     0, 1, 1, atr);

      indJson = StringFormat(
         ",\"ema_%d\":%.5f,\"ema_%d\":%.5f,\"ema_%d\":%.5f,"
         "\"rsi_%d\":%.2f,\"atr_%d\":%.5f",
         EMA_Fast, emaF[0], EMA_Mid, emaM[0], EMA_Slow, emaS[0],
         RSI_Period, rsi[0], ATR_Period, atr[0]
      );
   }

   string json = StringFormat(
      "{\"type\":\"bar\",\"symbol\":\"%s\",\"tf\":\"%s\","
      "\"time\":%d,\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,"
      "\"close\":%.5f,\"volume\":%d%s}",
      _Symbol, EnumToString(_Period),
      (int)rates[0].time, rates[0].open, rates[0].high,
      rates[0].low, rates[0].close, (int)rates[0].tick_volume,
      indJson
   );

   ZmqMsg msg(json);
   sender.send(msg, true);

   Print("Bar sent: ", _Symbol, " O=", rates[0].open, " H=", rates[0].high,
         " L=", rates[0].low, " C=", rates[0].close);
}

//+------------------------------------------------------------------+
void SendBarHistory(int count)
{
   MqlRates rates[];
   int copied = CopyRates(_Symbol, _Period, 1, count, rates);
   if(copied <= 0)
      return;

   for(int i = 0; i < copied; i++)
   {
      string json = StringFormat(
         "{\"type\":\"history\",\"symbol\":\"%s\",\"tf\":\"%s\","
         "\"time\":%d,\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,"
         "\"close\":%.5f,\"volume\":%d,\"index\":%d}",
         _Symbol, EnumToString(_Period),
         (int)rates[i].time, rates[i].open, rates[i].high,
         rates[i].low, rates[i].close, (int)rates[i].tick_volume, i
      );

      ZmqMsg msg(json);
      sender.send(msg, true);
   }

   Print("Sent ", copied, " history bars for ", _Symbol);
}
//+------------------------------------------------------------------+
