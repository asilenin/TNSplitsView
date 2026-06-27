import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.Lang;
using Toybox.FitContributor;

function rowsForMode(m) {            // 0=min,1=med,2=max
    if (m == 2) { return 1; }
    if (m == 1) { return 6; }
    return 8;
}

// Порог = "этот темп (сек/км) и быстрее", пока не наступит следующий порог.
function colorForPace(paceSec) {
    if (paceSec <= 0)   { return 0xFFFFFF; }   // нет данных — белый
    if (paceSec < 240)  { return 0xAA44FF; }   // быстрее 4:00 — фиолетовый
    if (paceSec < 270)  { return 0xFF0000; }   // 4:00–4:29 — красный
    if (paceSec < 300)  { return 0xFF8800; }   // 4:30–4:59 — оранжевый
    if (paceSec < 330)  { return 0xFFFF00; }   // 5:00–5:29 — жёлтый
    if (paceSec < 360)  { return 0x00DD00; }   // 5:30–5:59 — зелёный
    if (paceSec < 420)  { return 0x33CCFF; }   // 6:00–6:59 — голубой
    return 0xFFFFFF;                            // 7:00 и медленнее — белый
}

class SplitsApp extends Application.AppBase {
    var _view;
    function initialize() { AppBase.initialize(); }
    function getInitialView() {
        _view = new SplitsView();
        return [ _view, new SplitsDelegate(_view) ];
    }
    function onSettingsChanged() {
        if (_view != null) { _view.reloadSettings(); WatchUi.requestUpdate(); }
    }
}

class SplitsView extends WatchUi.DataField {
    // Запись списка: массив [type, t1, t2, t3, t4]
    //   type 0 = лап:    [0, lapNum, lapTimeSec, lapDistM, paceSec, tMsAbs]
    //   type 1 = лактат: [1, val10,  tMsAbs,     0,        0,       tMsAbs]
    // Для единообразия держим в каждом элементе абсолютный таймстамп в индексе [5].
    var _items;            // разнородный список, отсортирован по времени добавления
    var _lastTimeMs; var _lastDistM;
    var _topIndex; var _fontMode; var _w; var _h; var _tapFlash;
    var _lactateEnabled;

    // режим: 0 = список, 1 = ввод лактата
    var _mode;

    // ввод лактата
    var _val10; const MIN10 = 0; const MAX10 = 250;
    var _writeNow; var _savedFlash;

    // FIT
    var _fieldRecord;      // числовое record-поле (field 1)
    var _fieldSession;     // строка session (field 2)
    var _sessionStr;       // накопленная строка отметок

    function initialize() {
        DataField.initialize();
        _items = [];
        _lastTimeMs = 0; _lastDistM = 0.0;
        _topIndex = 0; _w = 0; _h = 0; _tapFlash = 0;
        _mode = 0;
        _val10 = 20; _writeNow = false; _savedFlash = 0;
        _sessionStr = "";
        reloadSettings();

        if (_lactateEnabled) {
            _fieldRecord = createField(
                "lactate", 1, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "mmol/L" }
            );
            _fieldSession = createField(
                "lactate_marks", 2, FitContributor.DATA_TYPE_STRING,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :count => 80 }
            );
        }
    }

    function reloadSettings() {
        var m = Application.Properties.getValue("fontMode");
        _fontMode = (m == null) ? 0 : m;
        var le = Application.Properties.getValue("lactateEnabled");
        _lactateEnabled = (le == null) ? false : le;
        if (!_lactateEnabled && _mode == 1) { _mode = 0; }  // если выключили — выходим из ввода
    }

    // ——— список ———
    function nItems() { return _items.size(); }

    function clampTop() {
        var rows = rowsForMode(_fontMode);
        var half = (rows - 1) / 2;
        var lo = half;
        var hi = nItems() - 1 + half;
        if (hi < lo) { hi = lo; }
        if (_topIndex < lo) { _topIndex = lo; }
        if (_topIndex > hi) { _topIndex = hi; }
    }

    function onTimerLap() {
        var info = Activity.getActivityInfo();
        var tMs = 0; var dM = 0.0;
        if (info != null) {
            if (info.timerTime != null) { tMs = info.timerTime; }
            if (info.elapsedDistance != null) { dM = info.elapsedDistance; }
        }
        var lapTime = (tMs - _lastTimeMs) / 1000.0;
        var lapDist = dM - _lastDistM;
        var pace = 0.0;
        if (lapDist > 0) { pace = lapTime / (lapDist / 1000.0); }
        var lapNum = countLaps() + 1;
        _items.add([ 0, lapNum, lapTime, lapDist, pace, tMs ]);
        _lastTimeMs = tMs; _lastDistM = dM;
        _topIndex = nItems() + 10;
        clampTop();
        WatchUi.requestUpdate();
    }

    function countLaps() {
        var n = 0;
        for (var i = 0; i < _items.size(); i += 1) {
            if (_items[i][0] == 0) { n += 1; }
        }
        return n;
    }

    function compute(info) {
        if (_writeNow && _fieldRecord != null) {
            _fieldRecord.setData(_val10 / 10.0);
            _writeNow = false;
        }
    }

    function pageOlder() { _topIndex -= 1; clampTop(); }
    function pageNewer() { _topIndex += 1; clampTop(); }
    function onLayout(dc) { _w = dc.getWidth(); _h = dc.getHeight(); }

    function fmtTime(sec) {
        var s = sec.toNumber(); return (s/60).format("%d") + ":" + (s%60).format("%02d");
    }
    function fmtPace(p) {
        if (p <= 0) { return "--"; }
        var s = p.toNumber(); return (s/60).format("%d") + ":" + (s%60).format("%02d");
    }
    function fmtClock(tMs) {
        var s = (tMs / 1000).toNumber();
        return (s/60).format("%d") + ":" + (s%60).format("%02d");
    }
    function valStr() {
        return (_val10/10).format("%d") + "," + (_val10%10).format("%d");
    }
    function valStrDot() {
        return (_val10/10).format("%d") + "." + (_val10%10).format("%d");
    }

    // ——— ввод лактата ———
    function bump(d10) {
        _val10 += d10;
        if (_val10 < MIN10) { _val10 = MIN10; }
        if (_val10 > MAX10) { _val10 = MAX10; }
        WatchUi.requestUpdate();
    }

    function confirmLactate() {
        // время
        var info = Activity.getActivityInfo();
        var tMs = 0;
        if (info != null && info.timerTime != null) { tMs = info.timerTime; }
        // запись в FIT record на ближайшем compute
        _writeNow = true;
        // в список как отдельная строка
        _items.add([ 1, _val10, tMs, 0, 0, tMs ]);
        // накопить session-строку
        var mark = valStrDot() + "@" + fmtClock(tMs);
        if (_sessionStr.equals("")) { _sessionStr = mark; }
        else { _sessionStr = _sessionStr + ";" + mark; }
        if (_fieldSession != null) { _fieldSession.setData(_sessionStr); }
        _savedFlash = 4;
        // вернуться в список и показать свежую отметку
        _mode = 0;
        _topIndex = nItems() + 10;
        clampTop();
        WatchUi.requestUpdate();
    }

    // ——— геометрия зон ввода (как в рабочем прототипе) ———
    // 3 колонки × 2 ряда, левый край — возврат
    function inputZoneAt(x, y) {
        if (x < _w * 0.16) { return "back"; }     // левый край — возврат в список
        var col = (x < _w/3) ? 0 : ((x < 2*_w/3) ? 1 : 2);
        var row = (y < _h/2) ? 0 : 1;
        if (row == 0 && col == 0) { return "p1";  }
        if (row == 0 && col == 2) { return "p01"; }
        if (row == 1 && col == 0) { return "m1";  }
        if (row == 1 && col == 2) { return "m01"; }
        if (row == 1 && col == 1) { return "ok";  }
        return "";
    }

    function handleInput(z) {
        if (z.equals("p1"))       { bump(10);  }
        else if (z.equals("p01")) { bump(1);   }
        else if (z.equals("m1"))  { bump(-10); }
        else if (z.equals("m01")) { bump(-1);  }
        else if (z.equals("ok"))  { confirmLactate(); }
        else if (z.equals("back")){ _mode = 0; clampTop(); WatchUi.requestUpdate(); }
    }

    // ——— тап в режиме списка ———
    function handleListTap(x, y) {
        // правый край при включённом лактате — переход в ввод
        if (_lactateEnabled && x > _w * 0.84) {
            _mode = 1;
            WatchUi.requestUpdate();
            return;
        }
        var third = _h / 3;
        if (y < third) { pageOlder(); }
        else if (y > third * 2) { pageNewer(); }
        // средняя зона в списке свободна (шрифт ушёл в настройки)
        _tapFlash = 3;
        WatchUi.requestUpdate();
    }

    // ——— отрисовка ———
    function onUpdate(dc) {
        if (_w == 0) { _w = dc.getWidth(); _h = dc.getHeight(); }
        if (_mode == 1) { drawInput(dc); }
        else { drawList(dc); }
    }

    function drawList(dc) {
        clampTop();
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK); dc.clear();

        if (_tapFlash > 0) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, 0, _w, 6);
            _tapFlash -= 1;
        }

        if (nItems() == 0) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_w/2, _h/2, Graphics.FONT_SMALL, "No splits yet",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            var rows = rowsForMode(_fontMode);

            if (_fontMode == 2) {                 // MAX — карточка одного элемента
                var idx = _topIndex;
                if (idx < 0) { idx = 0; }
                if (idx > nItems() - 1) { idx = nItems() - 1; }
                drawCard(dc, _items[idx]);
            } else {
                var font = Graphics.FONT_SMALL;
                if (_fontMode == 1) { font = Graphics.FONT_MEDIUM; }
                var rowH = _h / rows; var i = 0;
                while (i < rows) {
                    var idx = _topIndex - (rows - 1 - i);
                    if (idx >= 0 && idx < nItems()) {
                        drawRow(dc, _items[idx], (i * rowH) + (rowH / 2), font);
                    }
                    i += 1;
                }
            }
        }

        // правый переключатель в ввод (только если лактат включён)
        if (_lactateEnabled) {
            drawRightSwitch(dc);
        }
    }

    function drawRow(dc, it, y, font) {
        if (it[0] == 0) {
            // лап
            dc.setColor(colorForPace(it[4]), Graphics.COLOR_TRANSPARENT);
            var line;
            if (_fontMode == 0) {
                line = it[1].format("%d") + "  " + fmtTime(it[2]) + "  "
                     + (it[3]/1000.0).format("%.2f") + "  " + fmtPace(it[4]);
            } else {
                line = it[1].format("%d") + "  " + fmtTime(it[2]) + "  "
                     + (it[3]/1000.0).format("%.2f");
            }
            dc.drawText(_w/2, y, font, line,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            // лактат: 💧 значение  время
            dc.setColor(0x33CCFF, Graphics.COLOR_TRANSPARENT);
            var v = (it[1]/10).format("%d") + "," + (it[1]%10).format("%d");
            var line = "💧 " + v + "  " + fmtClock(it[2]);
            dc.drawText(_w/2, y, font, line,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    function drawCard(dc, it) {
        var cx = _w / 2;
        if (it[0] == 0) {
            dc.setColor(colorForPace(it[4]), Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, _h * 0.30, Graphics.FONT_NUMBER_MILD,
                "#" + it[1].format("%d") + "  " + fmtTime(it[2]),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, _h * 0.55, Graphics.FONT_MEDIUM,
                (it[3]/1000.0).format("%.2f") + " km",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, _h * 0.72, Graphics.FONT_MEDIUM,
                fmtPace(it[4]) + " /km",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            dc.setColor(0x33CCFF, Graphics.COLOR_TRANSPARENT);
            var v = (it[1]/10).format("%d") + "," + (it[1]%10).format("%d");
            dc.drawText(cx, _h * 0.35, Graphics.FONT_NUMBER_MILD,
                "💧 " + v,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, _h * 0.62, Graphics.FONT_MEDIUM,
                fmtClock(it[2]),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    function drawRightSwitch(dc) {
        var bw = (_w * 0.16).toNumber();
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(_w - bw, _h/2 - 45, bw, 90);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_w - bw/2, _h/2 - 14, Graphics.FONT_SMALL, "💧",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(_w - bw/2, _h/2 + 16, Graphics.FONT_SMALL, ">",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function drawInput(dc) {
        var cw = _w/3; var rh = _h/2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK); dc.clear();

        // зелёные плюс-зоны
        dc.setColor(0x00AA00, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, cw, rh);
        dc.fillRectangle(2*cw, 0, cw, rh);
        // красные минус-зоны
        dc.setColor(0xCC0000, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, rh, cw, rh);
        dc.fillRectangle(2*cw, rh, cw, rh);
        // белый OK
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(cw, rh, cw, rh);

        // подписи
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw/2,      rh/2, Graphics.FONT_MEDIUM, "+1",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(2*cw+cw/2, rh/2, Graphics.FONT_MEDIUM, "+0,1",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(cw/2,      rh+rh/2, Graphics.FONT_MEDIUM, "-1",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(2*cw+cw/2, rh+rh/2, Graphics.FONT_MEDIUM, "-0,1",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw+cw/2, rh+rh/2, Graphics.FONT_MEDIUM, "OK",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // значение белым на чёрном (верх-центр)
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw+cw/2, rh/2, Graphics.FONT_NUMBER_MEDIUM, valStr(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // левый край — возврат 🔁 <
        var bw = (_w * 0.16).toNumber();
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, rh - 45, bw, 90);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(bw/2, rh - 14, Graphics.FONT_SMALL, "🔁",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(bw/2, rh + 16, Graphics.FONT_SMALL, "<",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

class SplitsDelegate extends WatchUi.BehaviorDelegate {
    var _view;
    function initialize(v) { BehaviorDelegate.initialize(); _view = v; }
    function onTap(evt) {
        var c = evt.getCoordinates();
        if (_view._mode == 1) {
            _view.handleInput(_view.inputZoneAt(c[0], c[1]));
        } else {
            _view.handleListTap(c[0], c[1]);
        }
        return true;
    }
}
