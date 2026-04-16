//+------------------------------------------------------------------+
//|  Guardian_Heartbeat.mq5                                          |
//|  Sentinel MT: System Integrity — Heartbeat Writer  v3.0          |
//|  Author: M.Borasi                                                |
//|                                                                  |
//|  Writes a JSON heartbeat file every N seconds to:               |
//|    MQL5/Files/heartbeat_{TerminalName}.txt                       |
//|                                                                  |
//|  Writes two JSON files every N seconds to MQL5/Files/:           |
//|    heartbeat_{TerminalName}.txt  — account + trade data (v3.0)   |
//|    ea_status_{TerminalName}.txt  — EAs on all charts             |
//|  Timer-only EA — no trading, no interference.                    |
//+------------------------------------------------------------------+
#property copyright   "Sentinel MT: System Integrity — M.Borasi"
#property version     "3.00"
#property description "Sentinel MT — Heartbeat Writer v3.0"
#property description "Timer-only. No trading. No interference."

// ── User-configurable parameters ─────────────────────────────────────────────
// These are the ONLY settings the user should change.
input string            TerminalName      = "MT5_MAIN";        // Must match config.yaml terminal name exactly (case-sensitive)
input bool              ShowPanel         = true;               // Show info panel on chart
input ENUM_BASE_CORNER  PanelCorner       = CORNER_LEFT_UPPER; // Panel anchor corner
input int               PanelOffsetX      = 10;                // Panel X offset (pixels)
input int               PanelOffsetY      = 20;                // Panel Y offset (pixels)
input int               MagicSeed         = 47291;             // Change only if object name conflict with another EA
input int               TradeHistoryCount = 20;                // Closed trades shown [range: 1-50]

// ── Sentinel internal constants — DO NOT MODIFY ───────────────────────────────
// These values are calibrated for Sentinel MT. Changing them breaks monitoring.
#define _GHB_INTERVAL        15
#define _GHB_WRITE_EXTENDED  true
#define _GHB_WRITE_TRADES    true
#define _GHB_WRITE_DAILY_PNL true
#define _GHB_WRITE_POSITIONS true
#define _GHB_WRITE_PENDING   true

#define CLR_BG    C'13,13,20'
#define CLR_BDR   C'0,95,195'
#define CLR_TTL   C'55,155,255'
#define CLR_SEP   C'40,65,105'
#define CLR_LBL   C'105,125,150'
#define CLR_VAL   C'205,220,240'
#define CLR_OK    C'0,190,82'
#define CLR_ERR   C'205,48,48'
#define CLR_WARN  C'175,165,45'
#define FONT_N    "Consolas"
#define FSZ_T     11
#define FSZ_B     10
#define PW        390
#define PH        400
#define LH        23
#define PX        12
#define PY        10
#define C2        120

#define NOBJ 32
string OBJS[NOBJ]={"BG","TTL","SEP","L_TR","V_TR","L_ST","V_ST","L_LH","V_LH",
                   "L_CN","V_CN","L_FL","L_EQ","V_EQ","L_BL","V_BL",
                   "L_FP","V_FP","L_DD","V_DD","L_ML","V_ML","L_LV","V_LV",
                   "L_OT","V_OT","L_PN","V_PN","L_DR","V_DR","L_VR","SEP2"};

string   g_pfx=""; string g_hbf=""; string g_sef=""; datetime g_lw=0;
int      g_wc=0;   string g_ls="STARTING"; bool g_pr=false;
int      g_hist_count=20;
double   g_peak_equity=0.0;
double   g_max_dd_pct=0.0;
datetime g_session_start=0;

string N(const string s){return g_pfx+s;}

//+------------------------------------------------------------------+
//| US Eastern timezone offset — automatic DST detection            |
//+------------------------------------------------------------------+
int _ETOffset()
  {
   MqlDateTime d; datetime now=TimeGMT(); TimeToStruct(now,d);
   int yr=d.year;
   MqlDateTime t; t.year=yr; t.mon=3; t.day=1; t.hour=7; t.min=0; t.sec=0;
   datetime ds=StructToTime(t);
   int wd=(int)((ds/86400+4)%7);
   ds+=(datetime)(((wd==0?0:7-wd)+7)*86400);
   t.mon=11; t.day=1; t.hour=6;
   datetime de=StructToTime(t);
   wd=(int)((de/86400+4)%7);
   de+=(datetime)((wd==0?0:7-wd)*86400);
   return (now>=ds && now<de) ? -4 : -5;
  }

//+------------------------------------------------------------------+
//| DEAL_REASON integer → human-readable label                      |
//| MT5 ENUM_DEAL_REASON values                                      |
//+------------------------------------------------------------------+
string _DealReasonLabel(long reason)
  {
   switch((int)reason)
     {
      case  0: return "Manual (Client)";
      case  1: return "Manual (Mobile)";
      case  2: return "Manual (Web)";
      case  3: return "EA Logic";
      case  4: return "SL Hit";
      case  5: return "TP Hit";
      case  6: return "Stop Out";
      case  7: return "Rollover";
      case  8: return "VMargin";
      case  9: return "Split";
      case 10: return "Corporate Action";
      default: return "Unknown("+IntegerToString((int)reason)+")";
     }
  }

//+------------------------------------------------------------------+
//| ORDER_REASON integer → human-readable label                     |
//+------------------------------------------------------------------+
string _OrderReasonLabel(long reason)
  {
   switch((int)reason)
     {
      case 0: return "Manual (Client)";
      case 1: return "Manual (Mobile)";
      case 2: return "Manual (Web)";
      case 3: return "EA Logic";
      case 4: return "Expired";
      case 5: return "SL Hit";
      case 6: return "TP Hit";
      case 7: return "Stop Out";
      default: return "Unknown("+IntegerToString((int)reason)+")";
     }
  }

//+------------------------------------------------------------------+
//| Escape JSON string value                                         |
//+------------------------------------------------------------------+
string _JS(const string s)
  {
   string r=s;
   StringReplace(r,"\\","\\\\");
   StringReplace(r,"\"","\\\"");
   StringReplace(r,"\n","\\n");
   StringReplace(r,"\r","\\r");
   return r;
  }

int OnInit()
  {
   g_pfx=StringFormat("GHB_%d_",MagicSeed);
   g_hbf="heartbeat_"+TerminalName+".txt";
   g_sef="ea_status_"+TerminalName+".txt";
   g_hist_count=TradeHistoryCount;
   if(g_hist_count<1)  g_hist_count=1;
   if(g_hist_count>50) g_hist_count=50;
   g_session_start=TimeCurrent();
   g_peak_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(ShowPanel){_BuildPanel();g_pr=true;_UpdatePanel("STARTING");}
   if(!EventSetTimer(_GHB_INTERVAL))
     {if(!EventSetMillisecondTimer(_GHB_INTERVAL*1000)){Print("[GHB] CRITICAL: timer failed");return INIT_FAILED;}}
   _WriteHB();
   Print("[GHB] v3.0 Ready | ",TerminalName," | interval=",_GHB_INTERVAL,
         "s | broker=",AccountInfoString(ACCOUNT_COMPANY),
         " | leverage=1:",AccountInfoInteger(ACCOUNT_LEVERAGE),
         " | ET_offset=",_ETOffset(),
         " | demo=",AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO?"YES":"NO");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int r){EventKillTimer();if(g_pr){_DelPanel();g_pr=false;}Print("[GHB] v3.0 Stopped | reason=",_DR(r)," | writes=",g_wc);}
void OnTimer(){_WriteHB();_WriteEAStatus();}
void OnTick(){}

void OnChartEvent(const int id,const long& lp,const double& dp,const string& sp)
  {
   if(!g_pr)return;
   if(id==CHARTEVENT_CHART_CHANGE){_UpdatePanel(g_ls);return;}
   if(id==CHARTEVENT_OBJECT_DELETE&&StringFind(sp,g_pfx)==0)
     {_DelPanel();g_pr=false;_BuildPanel();g_pr=true;_UpdatePanel(g_ls);}
  }

//+------------------------------------------------------------------+
//| Main heartbeat writer                                            |
//+------------------------------------------------------------------+
void _WriteHB()
  {
   int h=FileOpen(g_hbf,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE){Print("[GHB] FileOpen FAILED: ",GetLastError());_UpdatePanel("ERR "+IntegerToString(GetLastError()));return;}
   datetime utc = TimeGMT();   // declared here — used both inside and outside WRITE_EXTENDED block
   string p="";
   if(_GHB_WRITE_EXTENDED)
     {
      // utc declared above
      double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
      double bl     = AccountInfoDouble(ACCOUNT_BALANCE);
      double ml     = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      int    ot     = (int)PositionsTotal();
      int    po     = (int)OrdersTotal();
      double fp     = eq-bl;
      long   lev    = AccountInfoInteger(ACCOUNT_LEVERAGE);
      double dp2    = _GHB_WRITE_DAILY_PNL?_DailyPnL():0.0;
      string bkr    = AccountInfoString(ACCOUNT_COMPANY);  StringReplace(bkr,"\"","'");
      string srv    = AccountInfoString(ACCOUNT_SERVER);    StringReplace(srv,"\"","'");
      long   lgn    = AccountInfoInteger(ACCOUNT_LOGIN);
      bool   dem    = (AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO);
      int    off    = _ETOffset();
      string tdp    = TerminalInfoString(TERMINAL_DATA_PATH);
      StringReplace(tdp,"\\","/");
      // v3.0 — new account + terminal fields
      double free_margin   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double margin_used   = AccountInfoDouble(ACCOUNT_MARGIN);
      double margin_init   = AccountInfoDouble(ACCOUNT_MARGIN_INITIAL);
      double margin_maint  = AccountInfoDouble(ACCOUNT_MARGIN_MAINTENANCE);
      double credit        = AccountInfoDouble(ACCOUNT_CREDIT);
      string currency      = AccountInfoString(ACCOUNT_CURRENCY);
      // account_name: some brokers (e.g. AvaTrade demo) return a numeric
      // internal ID instead of the account holder name. Detect and normalize.
      string acct_name_raw = AccountInfoString(ACCOUNT_NAME);
      string acct_name     = acct_name_raw;
      {
         bool is_numeric = true;
         for(int ci=0;ci<StringLen(acct_name_raw);ci++)
           {
            ushort c = StringGetCharacter(acct_name_raw,ci);
            if(c<'0'||c>'9'){is_numeric=false;break;}
           }
         if(is_numeric||StringLen(acct_name_raw)==0)
            acct_name = "";   // broker returned ID, not a real name — omit
      }
      int    limit_orders  = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
      bool   connected     = (TerminalInfoInteger(TERMINAL_CONNECTED)!=0);
      int    ping_ms       = (int)(TerminalInfoInteger(TERMINAL_PING_LAST)/1000);
      // TERMINAL_PING_LAST returns microseconds — divide by 1000 for milliseconds
      int    mt5_build     = (int)TerminalInfoInteger(TERMINAL_BUILD);
      string term_name     = TerminalInfoString(TERMINAL_NAME);
      // v3.0 — session tracking
      if(eq>g_peak_equity) g_peak_equity=eq;
      double dd_current_pct=(g_peak_equity>0)?(g_peak_equity-eq)/g_peak_equity*100.0:0.0;
      if(dd_current_pct>g_max_dd_pct) g_max_dd_pct=dd_current_pct;
      double total_lots=0.0, total_exp_usd=0.0;
      for(int pi=0;pi<ot;pi++){
         ulong ptk=PositionGetTicket(pi);
         if(ptk>0&&PositionSelectByTicket(ptk)){
            double pvol=PositionGetDouble(POSITION_VOLUME);
            string psym=PositionGetString(POSITION_SYMBOL);
            double pcs=SymbolInfoDouble(psym,SYMBOL_TRADE_CONTRACT_SIZE);
            double pprc=PositionGetDouble(POSITION_PRICE_CURRENT);
            total_lots+=pvol;
            total_exp_usd+=pvol*pcs*pprc;}}
      long session_secs=(long)(TimeCurrent()-g_session_start);
      // v3.0 — session stats
      double sess_gross_profit=0,sess_gross_loss=0,sess_comm=0,sess_swap=0;
      int    sess_wins=0,sess_losses=0,sess_total=0;
      _SessionStats(sess_gross_profit,sess_gross_loss,sess_comm,sess_swap,sess_wins,sess_losses,sess_total);

      p="{\"hb_version\":\"3.0\","
         +"\"terminal_data_path\":\""+tdp+"\","
         +"\"broker\":\""+bkr+"\","
         +"\"server\":\""+srv+"\","
         +"\"account_login\":"+IntegerToString(lgn)+","
         +"\"account_name\":\""+_JS(acct_name)+"\","
         +"\"account_currency\":\""+currency+"\","
         +"\"is_demo\":"+(dem?"true":"false")+","
         +"\"leverage\":"+IntegerToString(lev)+","
         +"\"limit_orders\":"+IntegerToString(limit_orders)+","
         +"\"et_offset\":"+IntegerToString(off)+","
         +"\"timestamp\":"+IntegerToString((long)utc)+","
         +"\"connected\":"+(connected?"true":"false")+","
         +"\"terminal_ping_ms\":"+IntegerToString(ping_ms)+","
         +"\"mt5_build\":"+IntegerToString(mt5_build)+","
         +"\"terminal_name\":\""+_JS(term_name)+"\","
         +"\"equity\":"+DoubleToString(eq,2)+","
         +"\"balance\":"+DoubleToString(bl,2)+","
         +"\"free_margin\":"+DoubleToString(free_margin,2)+","
         +"\"margin_used\":"+DoubleToString(margin_used,2)+","
         +"\"margin_initial\":"+DoubleToString(margin_init,2)+","
         +"\"margin_maintenance\":"+DoubleToString(margin_maint,2)+","
         +"\"margin_level\":"+DoubleToString(ml,1)+","
         +"\"credit\":"+DoubleToString(credit,2)+","
         +"\"open_trades\":"+IntegerToString(ot)+","
         +"\"pending_count\":"+IntegerToString(po)+","
         +"\"floating_pnl\":"+DoubleToString(fp,2)+","
         +"\"daily_pnl\":"+DoubleToString(dp2,2)+","
         +"\"total_exposure_lots\":"+DoubleToString(total_lots,2)+","
         +"\"total_exposure_usd\":"+DoubleToString(total_exp_usd,2)+","
         +"\"peak_equity_session\":"+DoubleToString(g_peak_equity,2)+","
         +"\"drawdown_current_pct\":"+DoubleToString(dd_current_pct,2)+","
         +"\"max_drawdown_session_pct\":"+DoubleToString(g_max_dd_pct,2)+","
         +"\"session_start_ts\":"+IntegerToString((long)g_session_start)+","
         +"\"session_duration_secs\":"+IntegerToString((int)session_secs)+","
         +"\"session_trades\":"+IntegerToString(sess_total)+","
         +"\"session_wins\":"+IntegerToString(sess_wins)+","
         +"\"session_losses\":"+IntegerToString(sess_losses)+","
         +"\"session_gross_profit\":"+DoubleToString(sess_gross_profit,2)+","
         +"\"session_gross_loss\":"+DoubleToString(sess_gross_loss,2)+","
         +"\"session_profit_factor\":"+DoubleToString(
              (sess_gross_loss!=0.0)?sess_gross_profit/MathAbs(sess_gross_loss):0.0,2)+","
         +"\"session_commission\":"+DoubleToString(sess_comm,2)+","
         +"\"session_swap\":"+DoubleToString(sess_swap,2);
      if(_GHB_WRITE_POSITIONS) p+=",\"open_positions\":"+_BuildPosJSON();
      if(_GHB_WRITE_PENDING) p+=",\"pending_orders\":"+_BuildPendingJSON();
      if(_GHB_WRITE_TRADES)  p+=",\"trades\":"+_BuildTradesJSON();
      p+="}";
     }
   else p=IntegerToString((long)utc);
   uint wr=FileWriteString(h,p);
   FileClose(h);
   if(wr==0){_UpdatePanel("WRITE FAIL");return;}
   g_lw=utc;g_wc++;_UpdatePanel("OK");
  }

//+------------------------------------------------------------------+
//| Open positions — full payload including point                   |
//+------------------------------------------------------------------+
string _BuildPosJSON()
  {
   int tot=(int)PositionsTotal();
   if(tot==0)return "[]";
   string arr="["; bool first=true;
   for(int i=0;i<tot;i++)
     {
      ulong tk=PositionGetTicket(i); if(tk==0)continue;
      if(!PositionSelectByTicket(tk))continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long   typ = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double cp  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      double pft = PositionGetDouble(POSITION_PROFIT);
      double swp = PositionGetDouble(POSITION_SWAP);
      long   mg  = PositionGetInteger(POSITION_MAGIC);
      string cmt = PositionGetString(POSITION_COMMENT);
      datetime ot_time = (datetime)PositionGetInteger(POSITION_TIME);
      string ts  = (typ==POSITION_TYPE_BUY)?"BUY":"SELL";
      // Point value for pip calculation
      double pt  = SymbolInfoDouble(sym,SYMBOL_POINT);
      int    dg  = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      double slp = (sl>0)?((typ==POSITION_TYPE_BUY)?(op-sl)/pt:(sl-op)/pt):0;
      double tpp = (tp>0)?((typ==POSITION_TYPE_BUY)?(tp-op)/pt:(op-tp)/pt):0;
      double cs      = SymbolInfoDouble(sym,SYMBOL_TRADE_CONTRACT_SIZE);
      double tv      = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
      double ts_sz   = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
      double risk_usd= (slp>0&&cs>0&&ts_sz>0)?(slp*pt/ts_sz*tv*vol):0.0;
      double acbal   = AccountInfoDouble(ACCOUNT_BALANCE);
      double risk_pct= (acbal>0&&risk_usd>0)?(risk_usd/acbal*100.0):0.0;
      int    age_min = (int)((TimeCurrent()-(datetime)PositionGetInteger(POSITION_TIME))/60);
      double sym_bid = SymbolInfoDouble(sym,SYMBOL_BID);
      double sym_ask = SymbolInfoDouble(sym,SYMBOL_ASK);
      double sym_spr = (ts_sz>0)?(sym_ask-sym_bid)/ts_sz:0.0;
      long   ltick   = SymbolInfoInteger(sym,SYMBOL_TIME);
      string item="{"
        +"\"ticket\":"+IntegerToString((long)tk)+","
        +"\"symbol\":\""+sym+"\","
        +"\"type\":\""+ts+"\","
        +"\"volume\":"+DoubleToString(vol,2)+","
        +"\"open_price\":"+DoubleToString(op,dg)+","
        +"\"current_price\":"+DoubleToString(cp,dg)+","
        +"\"sl\":"+DoubleToString(sl,dg)+","
        +"\"tp\":"+DoubleToString(tp,dg)+","
        +"\"sl_pts\":"+DoubleToString(slp,0)+","
        +"\"tp_pts\":"+DoubleToString(tpp,0)+","
        +"\"profit\":"+DoubleToString(pft,2)+","
        +"\"swap\":"+DoubleToString(swp,2)+","
        +"\"total_pnl\":"+DoubleToString(pft+swp,2)+","
        +"\"magic\":"+IntegerToString(mg)+","
        +"\"comment\":\""+_JS(cmt)+"\","
        +"\"open_time\":\""+TimeToString(ot_time,TIME_DATE|TIME_SECONDS)+"\","
        +"\"position_age_minutes\":"+IntegerToString(age_min)+","
        +"\"risk_usd\":"+DoubleToString(risk_usd,2)+","
        +"\"risk_pct\":"+DoubleToString(risk_pct,2)+","
        +"\"contract_size\":"+DoubleToString(cs,0)+","
        +"\"bid\":"+DoubleToString(sym_bid,dg)+","
        +"\"ask\":"+DoubleToString(sym_ask,dg)+","
        +"\"spread_pts\":"+DoubleToString(sym_spr,1)+","
        +"\"last_tick_ts\":"+IntegerToString((long)ltick)+","
        +"\"point\":"+DoubleToString(pt,_Digits+1)
        +"}";
      if(!first)arr+=","; arr+=item; first=false;
     }
   return arr+"]";
  }

//+------------------------------------------------------------------+
//| Pending orders — full payload with order_reason + expiration    |
//+------------------------------------------------------------------+
string _BuildPendingJSON()
  {
   int tot=(int)OrdersTotal();
   if(tot==0)return "[]";
   string arr="["; bool first=true;
   for(int i=0;i<tot;i++)
     {
      ulong tk=OrderGetTicket(i); if(tk==0)continue;
      if(!OrderSelect(tk))continue;
      string sym   = OrderGetString(ORDER_SYMBOL);
      long   typ   = OrderGetInteger(ORDER_TYPE);
      double vol   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);     // trigger price
      double sl    = OrderGetDouble(ORDER_SL);
      double tp    = OrderGetDouble(ORDER_TP);
      long   mg    = OrderGetInteger(ORDER_MAGIC);
      string cmt   = OrderGetString(ORDER_COMMENT);
      datetime placed  = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      datetime expiry  = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      long   reason    = OrderGetInteger(ORDER_REASON);
      int    dg        = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);

      // Order type string
      string ts="";
      switch((int)typ)
        {
         case ORDER_TYPE_BUY_LIMIT:       ts="BUY_LIMIT";       break;
         case ORDER_TYPE_SELL_LIMIT:      ts="SELL_LIMIT";      break;
         case ORDER_TYPE_BUY_STOP:        ts="BUY_STOP";        break;
         case ORDER_TYPE_SELL_STOP:       ts="SELL_STOP";       break;
         case ORDER_TYPE_BUY_STOP_LIMIT:  ts="BUY_STOP_LIMIT";  break;
         case ORDER_TYPE_SELL_STOP_LIMIT: ts="SELL_STOP_LIMIT"; break;
         default: ts="ORDER_"+IntegerToString((int)typ);
        }

      string expiry_str = (expiry>0)?TimeToString(expiry,TIME_DATE|TIME_SECONDS):"";

      string item="{"
        +"\"ticket\":"+IntegerToString((long)tk)+","
        +"\"symbol\":\""+sym+"\","
        +"\"type\":\""+ts+"\","
        +"\"volume\":"+DoubleToString(vol,2)+","
        +"\"trigger_price\":"+DoubleToString(price,dg)+","
        +"\"sl\":"+DoubleToString(sl,dg)+","
        +"\"tp\":"+DoubleToString(tp,dg)+","
        +"\"magic\":"+IntegerToString(mg)+","
        +"\"comment\":\""+_JS(cmt)+"\","
        +"\"placed_time\":\""+TimeToString(placed,TIME_DATE|TIME_SECONDS)+"\","
        +"\"expiration\":\""+expiry_str+"\","
        +"\"order_reason\":"+IntegerToString((int)reason)+","
        +"\"order_reason_label\":\""+_OrderReasonLabel(reason)+"\""
        +"}";
      if(!first)arr+=","; arr+=item; first=false;
     }
   return arr+"]";
  }

//+------------------------------------------------------------------+
//| Closed trades — full payload with deal_reason, commission, swap |
//| O(n) two-pass algorithm: pre-index IN deals, O(1) OUT lookup.  |
//+------------------------------------------------------------------+
string _BuildTradesJSON()
  {
   HistorySelect(TimeCurrent()-90*86400,TimeCurrent());
   int tot=(int)HistoryDealsTotal();
   string items[]; int found=0;

   // ── Pass 1: index all IN deals by position_id (single O(n) pass) ──────
   // Parallel arrays: _in_pos_id[k], _in_price[k], _in_time[k], _in_reason[k]
   // Bounded by tot (same as history count). Typical size: 10-500 entries.
   ulong  _in_pos_id[];  ArrayResize(_in_pos_id,  tot);
   double _in_price[];   ArrayResize(_in_price,    tot);
   datetime _in_time[];  ArrayResize(_in_time,     tot);
   long   _in_reason[];  ArrayResize(_in_reason,   tot);
   int    _in_cnt = 0;

   for(int k=0;k<tot;k++)
     {
      ulong tk2=HistoryDealGetTicket(k); if(tk2==0)continue;
      ENUM_DEAL_ENTRY e2=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk2,DEAL_ENTRY);
      if(e2!=DEAL_ENTRY_IN)continue;
      _in_pos_id[_in_cnt] = (ulong)HistoryDealGetInteger(tk2,DEAL_POSITION_ID);
      _in_price[_in_cnt]  = HistoryDealGetDouble(tk2,DEAL_PRICE);
      _in_time[_in_cnt]   = (datetime)HistoryDealGetInteger(tk2,DEAL_TIME);
      _in_reason[_in_cnt] = HistoryDealGetInteger(tk2,DEAL_REASON);
      _in_cnt++;
     }

   // ── Pass 2: iterate OUT deals, O(1) lookup from index ─────────────────
   for(int i=tot-1;i>=0&&found<g_hist_count;i--)
     {
      ulong tk=HistoryDealGetTicket(i); if(tk==0)continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_INOUT)continue;

      ENUM_DEAL_TYPE dt=(ENUM_DEAL_TYPE)HistoryDealGetInteger(tk,DEAL_TYPE);
      // NOTE: On position close, MT5 emits a deal whose DEAL_TYPE is OPPOSITE to the position.
      // DEAL_TYPE_BUY = closing deal that exits a SELL position → position was SELL.
      // DEAL_TYPE_SELL = closing deal that exits a BUY position → position was BUY.
      // We report the POSITION direction (what the trader held), not the deal direction.
      string ts=(dt==DEAL_TYPE_SELL)?"BUY":"SELL";   // invert: deal SELL = was long, deal BUY = was short

      datetime ct   = (datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      string   sym  = HistoryDealGetString(tk,DEAL_SYMBOL);
      double   vol  = HistoryDealGetDouble(tk,DEAL_VOLUME);
      double   cp   = HistoryDealGetDouble(tk,DEAL_PRICE);
      double   pft  = HistoryDealGetDouble(tk,DEAL_PROFIT);
      double   comm = HistoryDealGetDouble(tk,DEAL_COMMISSION);
      double   swp  = HistoryDealGetDouble(tk,DEAL_SWAP);
      double   net  = pft+comm+swp;
      long     mg   = HistoryDealGetInteger(tk,DEAL_MAGIC);
      string   cmt  = HistoryDealGetString(tk,DEAL_COMMENT);
      long     pos_id = HistoryDealGetInteger(tk,DEAL_POSITION_ID);
      long     reason = HistoryDealGetInteger(tk,DEAL_REASON);

      // Retrieve entry price, open_time, open_reason from pre-built index
      double   op        = 0;
      string   open_time = "";
      long     open_reason = -1;
      int      dg = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      double   pt = SymbolInfoDouble(sym,SYMBOL_POINT);
      if(dg==0)dg=5; if(pt==0.0)pt=0.00001;

      if(pos_id>0)
        {
         for(int k=0;k<_in_cnt;k++)   // O(m) over IN deals only, not ALL deals
           {
            if((long)_in_pos_id[k]==pos_id)
              {
               op          = _in_price[k];
               open_time   = TimeToString(_in_time[k],TIME_DATE|TIME_SECONDS);
               open_reason = _in_reason[k];
               break;
              }
           }
        }

      // Duration in seconds
      double dur_sec = 0;
      if(open_time!="")
        {
         datetime ot2_dt=(datetime)StringToTime(open_time);
         dur_sec=(ct>ot2_dt)?(double)(ct-ot2_dt):0;
        }

      // Pips: use POSITION direction (ts already inverted above), not deal direction
      double pips = 0;
      if(op>0 && pt>0)
        {
         // BUY position profits when close > open; SELL when close < open
         double raw_pips=(ts=="BUY")?(cp-op)/pt:(op-cp)/pt;
         // Normalize for 5-digit / 3-digit (JPY) brokers → standard pips
         if(dg==5||dg==3) raw_pips/=10.0;
         pips=raw_pips;
        }

      string item="{"
        +"\"ticket\":"+IntegerToString((long)tk)+","
        +"\"position_id\":"+IntegerToString(pos_id)+","
        +"\"symbol\":\""+sym+"\","
        +"\"type\":\""+ts+"\","
        +"\"volume\":"+DoubleToString(vol,2)+","
        +"\"open_price\":"+DoubleToString(op,dg)+","
        +"\"close_price\":"+DoubleToString(cp,dg)+","
        +"\"pips\":"+DoubleToString(pips,1)+","
        +"\"profit\":"+DoubleToString(pft,2)+","
        +"\"commission\":"+DoubleToString(comm,2)+","
        +"\"swap\":"+DoubleToString(swp,2)+","
        +"\"net_profit\":"+DoubleToString(net,2)+","
        +"\"magic\":"+IntegerToString(mg)+","
        +"\"comment\":\""+_JS(cmt)+"\","
        +"\"open_time\":\""+open_time+"\","
        +"\"close_time\":\""+TimeToString(ct,TIME_DATE|TIME_SECONDS)+"\","
        +"\"duration_seconds\":"+DoubleToString(dur_sec,0)+","
        +"\"deal_reason\":"+IntegerToString((int)reason)+","
        +"\"deal_reason_label\":\""+_DealReasonLabel(reason)+"\","
        +"\"open_reason\":"+IntegerToString((int)open_reason)+","
        +"\"open_reason_label\":\""+_OrderReasonLabel(open_reason)+"\","
        +"\"point\":"+DoubleToString(pt,dg+1)
        +"}";

      int sz=ArraySize(items);ArrayResize(items,sz+1);items[sz]=item;found++;
     }
   if(found==0)return "[]";
   string arr="["; for(int i=0;i<found;i++){arr+=items[i];if(i<found-1)arr+=",";}
   return arr+"]";
  }


//+------------------------------------------------------------------+
//| Session stats — today from ET midnight                          |
//+------------------------------------------------------------------+
void _SessionStats(double &gross_p,double &gross_l,double &comm,
                   double &swap_t,int &wins,int &losses,int &total)
  {
   gross_p=0;gross_l=0;comm=0;swap_t=0;wins=0;losses=0;total=0;
   int off=_ETOffset();
   datetime utc2=TimeGMT();
   long srv_off=(long)(TimeTradeServer()-utc2);
   long et_mn=(long)utc2-((long)utc2%86400)-(long)(off*3600);
   if((long)utc2<et_mn) et_mn-=86400;
   datetime ds=(datetime)(et_mn+srv_off);
   HistorySelect(ds,TimeTradeServer()+86400);
   int d=(int)HistoryDealsTotal();
   for(int i=0;i<d;i++)
     {
      ulong tk=HistoryDealGetTicket(i);if(tk==0)continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_INOUT)continue;
      double pft2=HistoryDealGetDouble(tk,DEAL_PROFIT);
      comm  +=HistoryDealGetDouble(tk,DEAL_COMMISSION);
      swap_t+=HistoryDealGetDouble(tk,DEAL_SWAP);
      total++;
      if(pft2>0){gross_p+=pft2;wins++;}else{gross_l+=pft2;losses++;}
     }
  }

//+------------------------------------------------------------------+
//| Period integer -> string                                        |
//+------------------------------------------------------------------+
string _PeriodStr(int p2)
  {
   switch(p2)
     {
      case PERIOD_M1:  return "M1";  case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15"; case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";  case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";  case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default: return "TF"+IntegerToString(p2);
     }
  }

//+------------------------------------------------------------------+
//| EA Status — scan all charts                                     |
//+------------------------------------------------------------------+
void _WriteEAStatus()
  {
   datetime utc2  = TimeGMT();
   bool     algG  = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)!=0);
   string   json  = "{"
      +"\"terminal\":\""+_JS(TerminalName)+"\","
      +"\"timestamp\":"+IntegerToString((long)utc2)+","
      +"\"algo_trading_global\":"+(algG?"true":"false")+","
      +"\"hb_version\":\"3.0\",";
   string charts  = "[";
   bool   first   = true;
   long   cid     = ChartFirst();
   while(cid>=0)
     {
      string sym2   = ChartSymbol(cid);
      int    period = (int)ChartPeriod(cid);
      string ea_nm  = ChartGetString(cid,CHART_EXPERT_NAME);
      if(StringLen(ea_nm)>0)
        {
         string gv  = "GHB_ERR_"+IntegerToString(cid);
         int    err = 0;
         string emsg= "";
         if(GlobalVariableCheck(gv)) err=(int)GlobalVariableGet(gv);
         string emf = "ea_err_"+IntegerToString(cid)+".txt";
         int    emh = FileOpen(emf,FILE_READ|FILE_TXT|FILE_ANSI);
         if(emh!=INVALID_HANDLE){emsg=FileReadString(emh);FileClose(emh);}
         string ci= "{"
            +"\"chart_id\":"+IntegerToString(cid)+","
            +"\"symbol\":\""+_JS(sym2)+"\","
            +"\"timeframe\":\""+_PeriodStr(period)+"\","
            +"\"ea_name\":\""+_JS(ea_nm)+"\","
            +"\"algo_trading\":"+(algG?"true":"false")+","
            +"\"last_error\":"+IntegerToString(err)+","
            +"\"error_msg\":\""+_JS(emsg)+"\""
            +"}";
         if(!first)charts+=",";
         charts+=ci;first=false;
        }
      cid=ChartNext(cid);
     }
   charts+="]";
   json+="\"charts\":"+charts+"}";
   int h=FileOpen(g_sef,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE){Print("[GHB] ea_status FAILED: ",GetLastError());return;}
   FileWriteString(h,json);
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Daily P&L (net, includes commission and swap)                   |
//+------------------------------------------------------------------+
double _DailyPnL()
  {
   int    off=_ETOffset();
   datetime utc=TimeGMT();
   long srv_off=TimeTradeServer()-utc;
   long et_midnight=(long)utc-((long)utc%86400)-((long)off*3600);
   if((long)utc<et_midnight) et_midnight-=86400;
   datetime ds=(datetime)(et_midnight+srv_off);
   HistorySelect(ds,TimeTradeServer()+86400);
   double tot=0; int d=(int)HistoryDealsTotal();
   for(int i=0;i<d;i++)
     {
      ulong tk=HistoryDealGetTicket(i); if(tk==0)continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_INOUT)continue;
      tot+=HistoryDealGetDouble(tk,DEAL_PROFIT)
          +HistoryDealGetDouble(tk,DEAL_SWAP)
          +HistoryDealGetDouble(tk,DEAL_COMMISSION);
     }
   return tot;
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void _BuildPanel()
  {
   long c=ChartID(); int x=PanelOffsetX, y=PanelOffsetY;
   _RC(c,N("BG"),x,y,PW,PH);
   _LC(c,N("TTL"),x+PX,y+PY,"SENTINEL MT  |  System Integrity  v3.0",FONT_N,FSZ_T,CLR_TTL);
   _LC(c,N("SEP"),x+PX,y+PY+LH+2,"-------------------------------------------",FONT_N,7,CLR_SEP);
   int r=y+PY+LH*2;
   _LC(c,N("L_TR"),x+PX,r,"Terminal :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_TR"),x+PX+C2,r,TerminalName,FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_ST"),x+PX,r,"Status   :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_ST"),x+PX+C2,r,"STARTING",FONT_N,FSZ_B,CLR_WARN);r+=LH;
   _LC(c,N("L_LH"),x+PX,r,"Last HB  :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_LH"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_CN"),x+PX,r,"Writes   :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_CN"),x+PX+C2,r,"0",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_FL"),x+PX,r,"File: "+g_hbf,FONT_N,8,CLR_SEP);r+=LH;
   _LC(c,N("L_EQ"),x+PX,r,"Equity   :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_EQ"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_BL"),x+PX,r,"Balance  :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_BL"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_FP"),x+PX,r,"Float PnL:",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_FP"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_DD"),x+PX,r,"Drawdown :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_DD"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_ML"),x+PX,r,"Margin   :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_ML"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_LV"),x+PX,r,"Leverage :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_LV"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_OT"),x+PX,r,"Positions:",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_OT"),x+PX+C2,r,"0",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_PN"),x+PX,r,"Day P&L  :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_PN"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_DR"),x+PX,r,"Open P&L :",FONT_N,FSZ_B,CLR_LBL);_LC(c,N("V_DR"),x+PX+C2,r,"---",FONT_N,FSZ_B,CLR_VAL);r+=LH;
   _LC(c,N("L_VR"),x+PX,r,"HB v3.0  |  "+TerminalName,FONT_N,8,CLR_SEP);
   _LC(c,N("SEP2"),x+PX,r+LH,"",FONT_N,8,CLR_SEP);
   ChartRedraw(c);
  }

void _UpdatePanel(const string st)
  {
   g_ls=st; if(!g_pr)return;
   long c=ChartID();
   string stxt=st=="OK"?"OK  [ACTIVE]":st=="STARTING"?"STARTING ...":st;
   color sc=st=="OK"?CLR_OK:st=="STARTING"?CLR_WARN:CLR_ERR;
   string ls=g_lw>0?TimeToString(g_lw,TIME_DATE|TIME_SECONDS)+" UTC":"---";
   ObjectSetString(c,N("V_ST"),OBJPROP_TEXT,stxt);ObjectSetInteger(c,N("V_ST"),OBJPROP_COLOR,(long)sc);
   ObjectSetString(c,N("V_LH"),OBJPROP_TEXT,ls);
   ObjectSetString(c,N("V_CN"),OBJPROP_TEXT,IntegerToString(g_wc));
   if(_GHB_WRITE_EXTENDED)
     {
      double eq=AccountInfoDouble(ACCOUNT_EQUITY);  double bl=AccountInfoDouble(ACCOUNT_BALANCE);
      double ml=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL); int ot=(int)PositionsTotal();
      long   lev=AccountInfoInteger(ACCOUNT_LEVERAGE);
      double fp=eq-bl; double dd=(bl>0&&eq<bl)?((bl-eq)/bl*100.0):0.0;
      double dp=_GHB_WRITE_DAILY_PNL?_DailyPnL():0.0;
      double op_pnl=0;
      for(int i=0;i<ot;i++){ulong tk=PositionGetTicket(i);if(tk>0&&PositionSelectByTicket(tk))op_pnl+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);}
      string fps=(fp>=0?"+":"")+DoubleToString(fp,2);
      string pns=(dp>=0?"+":"")+DoubleToString(dp,2);
      string ops=(op_pnl>=0?"+":"")+DoubleToString(op_pnl,2);
      string mls=ml>0?DoubleToString(ml,1)+"%":"---";
      string lvs="1:"+IntegerToString(lev);
      color fc=fp>0?CLR_OK:fp<0?CLR_ERR:CLR_VAL;
      color dc=dd>=5?CLR_ERR:dd>=2?CLR_WARN:CLR_OK;
      color pc=dp>0?CLR_OK:dp<0?CLR_ERR:CLR_VAL;
      color mc=ml>200?CLR_OK:ml>100?CLR_WARN:CLR_ERR;
      color oc=op_pnl>0?CLR_OK:op_pnl<0?CLR_ERR:CLR_VAL;
      ObjectSetString(c,N("V_EQ"),OBJPROP_TEXT,DoubleToString(eq,2));
      ObjectSetString(c,N("V_BL"),OBJPROP_TEXT,DoubleToString(bl,2));
      ObjectSetString(c,N("V_FP"),OBJPROP_TEXT,fps); ObjectSetInteger(c,N("V_FP"),OBJPROP_COLOR,(long)fc);
      ObjectSetString(c,N("V_DD"),OBJPROP_TEXT,DoubleToString(dd,1)+"%"); ObjectSetInteger(c,N("V_DD"),OBJPROP_COLOR,(long)dc);
      ObjectSetString(c,N("V_ML"),OBJPROP_TEXT,mls); ObjectSetInteger(c,N("V_ML"),OBJPROP_COLOR,(long)mc);
      ObjectSetString(c,N("V_LV"),OBJPROP_TEXT,lvs);
      ObjectSetString(c,N("V_OT"),OBJPROP_TEXT,IntegerToString(ot));
      ObjectSetString(c,N("V_PN"),OBJPROP_TEXT,pns); ObjectSetInteger(c,N("V_PN"),OBJPROP_COLOR,(long)pc);
      ObjectSetString(c,N("V_DR"),OBJPROP_TEXT,ops); ObjectSetInteger(c,N("V_DR"),OBJPROP_COLOR,(long)oc);
     }
   ChartRedraw(c);
  }

void _DelPanel(){long c=ChartID();for(int i=0;i<NOBJ;i++)ObjectDelete(c,N(OBJS[i]));ChartRedraw(c);}

void _RC(long c,string n,int x,int y,int w,int h)
  {if(ObjectFind(c,n)>=0)ObjectDelete(c,n);ObjectCreate(c,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(c,n,OBJPROP_CORNER,(long)PanelCorner);ObjectSetInteger(c,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(c,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(c,n,OBJPROP_XSIZE,w);ObjectSetInteger(c,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(c,n,OBJPROP_BGCOLOR,(long)CLR_BG);ObjectSetInteger(c,n,OBJPROP_BORDER_COLOR,(long)CLR_BDR);
   ObjectSetInteger(c,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);ObjectSetInteger(c,n,OBJPROP_WIDTH,1);
   ObjectSetInteger(c,n,OBJPROP_BACK,false);ObjectSetInteger(c,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(c,n,OBJPROP_HIDDEN,true);ObjectSetInteger(c,n,OBJPROP_ZORDER,0);}

void _LC(long c,string n,int x,int y,string t,string f,int fs,color cl)
  {if(ObjectFind(c,n)>=0)ObjectDelete(c,n);ObjectCreate(c,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(c,n,OBJPROP_CORNER,(long)PanelCorner);ObjectSetInteger(c,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(c,n,OBJPROP_YDISTANCE,y);ObjectSetString(c,n,OBJPROP_TEXT,t);ObjectSetString(c,n,OBJPROP_FONT,f);
   ObjectSetInteger(c,n,OBJPROP_FONTSIZE,fs);ObjectSetInteger(c,n,OBJPROP_COLOR,(long)cl);
   ObjectSetInteger(c,n,OBJPROP_BACK,false);ObjectSetInteger(c,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(c,n,OBJPROP_HIDDEN,true);ObjectSetInteger(c,n,OBJPROP_ZORDER,1);}

string _DR(const int r)
  {switch(r){case REASON_PROGRAM:return"Program";case REASON_REMOVE:return"Removed";
   case REASON_RECOMPILE:return"Recompile";case REASON_CHARTCHANGE:return"ChartChange";
   case REASON_CHARTCLOSE:return"ChartClose";case REASON_PARAMETERS:return"Parameters";
   case REASON_ACCOUNT:return"Account";case REASON_TEMPLATE:return"Template";
   case REASON_INITFAILED:return"InitFailed";case REASON_CLOSE:return"TerminalClose";
   default:return"Unknown("+IntegerToString(r)+")";}}
