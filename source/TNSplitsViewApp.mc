import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.Lang;
import Toybox.System;
using Toybox.FitContributor;

function rowsForMode(m) {            // 0=min,1=med,2=max
    if (m == 2) { return 1; }
    if (m == 1) { return 5; }       // MID — карусель 5 строк, центр активный
    return 8;
}

// палитра цветов по индексу (0..6)
function paletteColor(idx) {
    if (idx == 0) { return 0xFFFFFF; }   // белый
    if (idx == 1) { return 0x33CCFF; }   // голубой
    if (idx == 2) { return 0x00DD00; }   // зелёный
    if (idx == 3) { return 0xFFFF00; }   // жёлтый
    if (idx == 4) { return 0xFF8800; }   // оранжевый
    if (idx == 5) { return 0xFF0000; }   // красный
    return 0xAA44FF;                     // 6 = фиолетовый
}

// парсинг "mm:ss" -> секунды. Возвращает -1 при ошибке формата.
function parseMMSS(s) {
    if (s == null) { return -1; }
    var str = s.toString();
    var colon = str.find(":");
    if (colon == null) { return -1; }
    var mm = str.substring(0, colon);
    var ss = str.substring(colon + 1, str.length());
    if (mm.length() == 0 || ss.length() == 0) { return -1; }
    var m = mm.toNumber();
    var sec = ss.toNumber();
    if (m == null || sec == null) { return -1; }
    if (m < 0 || m > 59 || sec < 0 || sec > 59) { return -1; }
    return m * 60 + sec;
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
    var _listMode;         // 0=MIN,1=MID,2=MAX,3=Cycle tap,4=Cycle timer
    var _touchOn;          // тач есть физически И включён настройкой
    var _cycleSec;         // интервал автоцикла (сек)
    var _cycleAccum;       // накопитель секунд для автоцикла

    // настройки порогов/цветов
    var _thr;              // массив 6 порогов в сек/км (канонический формат)
    var _col;              // массив 7 цветов (0xRRGGBB)
    var _settingsError;    // строка ошибки парсинга или null
    var _useMiles;         // системные единицы: true=мили

    // режим: 0 = список, 1 = ввод лактата
    var _mode;

    // ввод лактата
    var _val10; const MIN10 = 0; const MAX10 = 250;
    var _pending; var _holdSec; var _savedFlash;

    // FIT
    var _fieldRecord;      // числовое record-поле (field 1)
    var _fieldSession;     // строка session (field 2)
    var _sessionStr;       // накопленная строка отметок

    function initialize() {
        DataField.initialize();
        _items = [];
        _lastTimeMs = 0; _lastDistM = 0.0;
        _topIndex = 0; _w = 0; _h = 0; _tapFlash = 0;
        _curLapTime = 0.0; _curLapDist = 0.0; _curLapPace = 0.0;
        _mode = 0;
        _fontMode = 0;
        _settingsError = null;
        _touchOn = true; _cycleSec = 5; _cycleAccum = 0;
        _val10 = 20; _pending = 0; _holdSec = 0; _savedFlash = 0;
        _sessionStr = "";
        reloadSettings();

        if (_lactateEnabled) {
            _fieldRecord = createField(
                "lactate", 1, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "mmol/L" }
            );
            // session-строка временно отключена для диагностики
            _fieldSession = null;
        }
    }

    function reloadSettings() {
        // есть ли тач физически
        var ds = System.getDeviceSettings();
        var hasTouch = (ds != null && ds.isTouchScreen);

        // настройка использования тача
        var ut = Application.Properties.getValue("useTouch");
        var wantTouch = (ut == null) ? true : ut;
        // тач активен только если он есть физически И включён настройкой
        _touchOn = hasTouch && wantTouch;

        // режим списка: 0=MIN,1=MID,2=MAX,3=Cycle by tap,4=Cycle by timer
        var lm = Application.Properties.getValue("listMode");
        _listMode = (lm == null) ? 3 : lm;
        if (_listMode <= 2) { _fontMode = _listMode; }   // фиксированный режим
        if (_fontMode == null) { _fontMode = 0; }
        // Cycle by tap без тача переключаться не сможет — но это не застревание:
        // список показывается, просто один режим. Описано в настройках.

        // интервал автоцикла
        var cs = Application.Properties.getValue("cycleSec");
        _cycleSec = (cs == null || cs < 1) ? 5 : cs;
        _cycleAccum = 0;

        // лактат: требует активного тача
        var le = Application.Properties.getValue("lactateEnabled");
        _lactateEnabled = ((le == null) ? false : le) && _touchOn;
        if (!_lactateEnabled && _mode == 1) { _mode = 0; }

        // системные единицы (для отображения списка)
        _useMiles = false;
        if (ds != null && ds.paceUnits == System.UNIT_STATUTE) { _useMiles = true; }

        // единицы ввода порогов
        var tu = Application.Properties.getValue("thresholdUnit");
        var inputMiles = (tu != null && tu == 1);

        // читаем 6 порогов mm:ss, парсим, конвертим в сек/км (канон)
        _settingsError = null;
        _thr = new [6];
        var keys = ["pace1","pace2","pace3","pace4","pace5","pace6"];
        for (var i = 0; i < 6; i += 1) {
            var raw = Application.Properties.getValue(keys[i]);
            var secs = parseMMSS(raw);
            if (secs < 0) {
                // ошибка формата — запомнить и показать экран
                var shown = (raw == null) ? "" : raw.toString();
                _settingsError = "Threshold " + (i+1).format("%d")
                    + " invalid: \"" + shown + "\"";
                _thr[i] = 9999;   // заглушка, экран всё равно покажет ошибку
            } else {
                // secs — сек на введённую единицу. Канон: сек/км.
                if (inputMiles) {
                    // сек/милю -> сек/км : делим на 1.609344
                    _thr[i] = (secs / 1.609344).toNumber();
                } else {
                    _thr[i] = secs;
                }
            }
        }

        // цвета 7 зон
        _col = new [7];
        var ckeys = ["color1","color2","color3","color4","color5","color6","color7"];
        for (var j = 0; j < 7; j += 1) {
            var ci = Application.Properties.getValue(ckeys[j]);
            _col[j] = paletteColor((ci == null) ? 0 : ci);
        }
    }

    // цвет по темпу (сек/км) на основе настроенных порогов/цветов
    function colorFor(paceSec) {
        if (paceSec <= 0) { return 0xFFFFFF; }
        for (var i = 0; i < 6; i += 1) {
            if (paceSec < _thr[i]) { return _col[i]; }
        }
        return _col[6];   // медленнее последнего порога — зона 7
    }

    // ——— список ———
    function nItems() { return _items.size() + 1; }   // +1 живой текущий круг (виртуальная строка в конце)

    // живые значения текущего круга (обновляются в compute)
    var _curLapTime = 0.0;   // сек
    var _curLapDist = 0.0;   // м
    var _curLapPace = 0.0;   // сек/км

    // вернуть запись по индексу: реальные лапы из _items, последний индекс — живой круг
    function itemAt(idx) {
        if (idx < _items.size()) { return _items[idx]; }
        // виртуальная живая строка: type 0, номер = countLaps()+1, маркер времени -1
        return [ 0, countLaps() + 1, _curLapTime, _curLapDist, _curLapPace, -1 ];
    }

    function clampTop() {
        if (_fontMode == 1 || _fontMode == 2) {
            // MID и MAX: _topIndex = индекс активной/центральной записи
            if (_topIndex < 0) { _topIndex = 0; }
            if (_topIndex > nItems() - 1) { _topIndex = nItems() - 1; }
            if (nItems() == 0) { _topIndex = 0; }
            return;
        }
        // MIN: _topIndex = индекс нижней видимой строки (окно)
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
        // новый круг стартует с нуля
        _curLapTime = 0.0; _curLapDist = 0.0; _curLapPace = 0.0;
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
        // автоцикл режима по таймеру (listMode==4), раз в секунду
        if (_listMode == 4 && _mode == 0) {
            _cycleAccum += 1;
            if (_cycleAccum >= _cycleSec) {
                _cycleAccum = 0;
                _fontMode = (_fontMode + 1) % 3;
                clampTop();
                WatchUi.requestUpdate();
            }
        }
        // живые значения текущего круга = общее − накопленное на последней отсечке
        if (info != null) {
            var tMs = (info.timerTime != null) ? info.timerTime : _lastTimeMs;
            var dM  = (info.elapsedDistance != null) ? info.elapsedDistance : _lastDistM;
            _curLapTime = (tMs - _lastTimeMs) / 1000.0;
            _curLapDist = dM - _lastDistM;
            // темп считаем только когда набралось >10 м, иначе мусор на старте круга
            if (_curLapDist > 10.0) {
                _curLapPace = _curLapTime / (_curLapDist / 1000.0);
            } else {
                _curLapPace = 0.0;   // 0 => fmtPace покажет "--"
            }
            WatchUi.requestUpdate();   // тикаем живую строку каждую секунду
        }

        if (_fieldRecord == null) { return; }
        // Буфер _pending: по тапу OK туда кладётся значение замера, и держится
        // _holdSec секунд. Каждую секунду пишем _pending в плот. Значение держим
        // несколько секунд, потому что Garmin прореживает поток на длинных
        // тренировках (~1 запись в 3с) — одиночная точка выпала бы. Держим 10с,
        // чтобы значение гарантированно попало в сохранённые сэмплы.
        _fieldRecord.setData(_pending / 10.0);
        if (_pending != 0) {
            _holdSec -= 1;
            if (_holdSec <= 0) {
                _pending = 0;   // время держания вышло — дальше нули
            }
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

    // дистанция (метры) в системных единицах: км или мили
    function fmtDist(meters) {
        if (_useMiles) {
            return (meters / 1609.344).format("%.2f");
        }
        return (meters / 1000.0).format("%.2f");
    }

    // темп (сек/км канон) в системных единицах: мин:сек на км или на милю
    function fmtPaceU(paceSecPerKm) {
        if (paceSecPerKm <= 0) { return "--"; }
        var p = paceSecPerKm;
        if (_useMiles) { p = paceSecPerKm * 1.609344; }  // сек/км -> сек/милю
        var s = p.toNumber();
        return (s/60).format("%d") + ":" + (s%60).format("%02d");
    }

    function distUnit() { return _useMiles ? "mi" : "km"; }
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
        // кладём значение в буфер; compute запишет его в плот и обнулит буфер
        _pending = _val10;
        _holdSec = 10;   // держать значение 10с, чтобы пережить прореживание потока
        // в список как отдельная строка
        _items.add([ 1, _val10, tMs, 0, 0, tMs ]);
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
        // возврат — левый край ТОЛЬКО в средней полосе по высоте (чтобы +1/-1 в углах работали)
        if (x < _w * 0.16 && y > _h * 0.38 && y < _h * 0.62) { return "back"; }
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
        if (!_touchOn) { return; }   // тач выключен/отсутствует — игнорируем
        // правый край при включённом лактате — переход в ввод
        if (_lactateEnabled && x > _w - zoneW()) {
            _mode = 1;
            WatchUi.requestUpdate();
            return;
        }
        var third = _h / 3;
        if (y < third) { pageOlder(); }
        else if (y > third * 2) { pageNewer(); }
        else {
            // центр-тап переключает плотность списка только в режиме "Cycle by tap"
            if (_listMode == 3) {
                _fontMode = (_fontMode + 1) % 3;
                clampTop();
            }
        }
        _tapFlash = 3;
        WatchUi.requestUpdate();
    }

    // ——— отрисовка ———
    function onUpdate(dc) {
        if (_w == 0) { _w = dc.getWidth(); _h = dc.getHeight(); }
        if (_settingsError != null) { drawError(dc); return; }
        if (_mode == 1) { drawInput(dc); }
        else { drawList(dc); }
    }

    function drawError(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK); dc.clear();
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_w/2, _h*0.30, Graphics.FONT_SMALL, "Settings error",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_w/2, _h*0.47, Graphics.FONT_XTINY, _settingsError,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(_w/2, _h*0.62, Graphics.FONT_XTINY, "Use mm:ss (e.g. 4:30)",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function drawList(dc) {
        clampTop();
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK); dc.clear();

        if (_tapFlash > 0) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, 0, _w, (_h*0.013).toNumber());
            _tapFlash -= 1;
        }

        if (_fontMode == 2) {                     // MAX — карточка одного элемента
            var idx = _topIndex;
            if (idx < 0) { idx = 0; }
            if (idx > nItems() - 1) { idx = nItems() - 1; }
            drawCard(dc, itemAt(idx));
        } else if (_fontMode == 1) {              // MID — карусель 5 строк, центр активный
            drawCarousel(dc);
        } else {                                  // MIN — 8 строк
            var rows = rowsForMode(_fontMode);
            var font = Graphics.FONT_SMALL;
            var rowH = _h / rows; var i = 0;
            while (i < rows) {
                var idx = _topIndex - (rows - 1 - i);
                if (idx >= 0 && idx < nItems()) {
                    var yc = (i * rowH) + (rowH / 2);
                    if (idx == nItems() - 1) {
                        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                        var lx0 = (_w * 0.10).toNumber();
                        var lx1 = _lactateEnabled ? (_w * 0.78).toNumber() : (_w * 0.90).toNumber();
                        dc.drawLine(lx0, (i * rowH).toNumber(), lx1, (i * rowH).toNumber());
                    }
                    drawRow(dc, itemAt(idx), yc, font);
                }
                i += 1;
            }
        }

        // правый переключатель в ввод (только если лактат включён)
        if (_lactateEnabled) {
            drawRightSwitch(dc);
        }
    }

    // ширина зарезервированной зоны переключения (на 5px уже, чтобы дать списку место)
    function zoneW() {
        return (_w * 0.16).toNumber() - 5;
    }

    // центр области списка с учётом правой зоны переключения
    function listCx() {
        if (_lactateEnabled) {
            var bw = zoneW();
            return (_w - bw) / 2 - 2;   // -2px: отодвинуть текст от зоны, чтобы цифры не прилипали
        }
        return _w / 2;
    }

    function drawRow(dc, it, y, font) {
        if (it[0] == 0) {
            // лап (живой круг it[5]==-1 — белым, записанные — по темпу)
            if (it[5] == -1) { dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT); }
            else { dc.setColor(colorFor(it[4]), Graphics.COLOR_TRANSPARENT); }
            var line;
            if (_fontMode == 0) {
                line = it[1].format("%d") + "  " + fmtTime(it[2]) + "  "
                     + fmtDist(it[3]) + "  " + fmtPaceU(it[4]);
            } else {
                line = it[1].format("%d") + "  " + fmtTime(it[2]) + "  "
                     + fmtDist(it[3]);
            }
            if (_fontMode == 0) {
                dc.drawText((_w*0.02).toNumber(), y, font, line,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            } else {
                dc.drawText(listCx(), y, font, line,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        } else {
            // лактат: 💧 значение  время
            dc.setColor(0x33CCFF, Graphics.COLOR_TRANSPARENT);
            var v = (it[1]/10).format("%d") + "," + (it[1]%10).format("%d");
            var line = "💧 " + v + "  " + fmtClock(it[2]);
            if (_fontMode == 0) {
                dc.drawText((_w*0.02).toNumber(), y, font, line,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            } else {
                dc.drawText(listCx(), y, font, line,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }
    }

    // MID-карусель: 5 строк, центр (_topIndex) — активный/крупный, к краям мельче.
    // Центрируем имеющиеся: активная запись всегда по центру, пустые слоты пусты.
    function drawCarousel(dc) {
        var center = _topIndex;
        var ys = [ _h * 0.13, _h * 0.30, _h * 0.50, _h * 0.70, _h * 0.87 ];
        var fonts = [
            Graphics.FONT_TINY,    // 1 край
            Graphics.FONT_SMALL,   // 2
            Graphics.FONT_MEDIUM,  // 3 центр (активный) — крупная
            Graphics.FONT_SMALL,   // 4
            Graphics.FONT_TINY     // 5 край
        ];
        var off = [ -2, -1, 0, 1, 2 ];
        for (var i = 0; i < 5; i += 1) {
            var idx = center + off[i];
            if (idx >= 0 && idx < nItems()) {
                // линия над живым треком (последний индекс)
                if (idx == nItems() - 1) {
                    dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                    var lx0 = (_w * 0.12).toNumber();
                    var lx1 = _lactateEnabled ? (_w * 0.76).toNumber() : (_w * 0.88).toNumber();
                    var ly = (ys[i] - _h * 0.085).toNumber();
                    dc.drawLine(lx0, ly, lx1, ly);
                }
                drawRowFont(dc, itemAt(idx), ys[i], fonts[i], off[i] == 0);
            }
        }
    }

    // строка с заданным шрифтом; active=true подсвечивает центр
    function drawRowFont(dc, it, y, font, active) {
        if (it[0] == 0) {
            if (it[5] == -1) { dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT); }
            else { dc.setColor(colorFor(it[4]), Graphics.COLOR_TRANSPARENT); }
            var line;
            if (active) {
                // центральная (активная) строка — без номера отрезка (избыточен)
                line = fmtTime(it[2]) + "  "
                     + fmtDist(it[3]) + "  " + fmtPaceU(it[4]);
            } else {
                line = it[1].format("%d") + "  " + fmtTime(it[2]) + "  "
                     + fmtDist(it[3]) + "  " + fmtPaceU(it[4]);
            }
            dc.drawText(listCx(), y, font, line,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            dc.setColor(0x33CCFF, Graphics.COLOR_TRANSPARENT);
            var v = (it[1]/10).format("%d") + "," + (it[1]%10).format("%d");
            var line = "💧 " + v + "  " + fmtClock(it[2]);
            dc.drawText(listCx(), y, font, line,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    function drawCard(dc, it) {
        var cx = listCx();
        if (it[0] == 0) {
            if (it[5] == -1) { dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT); }
            else { dc.setColor(colorFor(it[4]), Graphics.COLOR_TRANSPARENT); }
            // номер отрезка — самый мелкий шрифт, отдельной строкой
            dc.drawText(cx, _h * 0.20, Graphics.FONT_XTINY,
                it[1].format("%d"),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            // время — отдельной строкой
            dc.drawText(cx, _h * 0.40, Graphics.FONT_NUMBER_MILD,
                fmtTime(it[2]),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, _h * 0.62, Graphics.FONT_MEDIUM,
                fmtDist(it[3]) + " " + distUnit(),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, _h * 0.78, Graphics.FONT_MEDIUM,
                fmtPaceU(it[4]) + " /" + distUnit(),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            dc.setColor(0x33CCFF, Graphics.COLOR_TRANSPARENT);
            var v = (it[1]/10).format("%d") + "," + (it[1]%10).format("%d");
            dc.drawText(cx, _h * 0.35, Graphics.FONT_NUMBER_MILD,
                "LA: " + v,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, _h * 0.62, Graphics.FONT_MEDIUM,
                fmtClock(it[2]),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    function drawRightSwitch(dc) {
        var bw = zoneW();
        // компактный квадрат по центру правого края (касание зарезервировано на всю высоту в handleListTap)
        var halfH = (_h * 0.10).toNumber();
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(_w - bw, _h/2 - halfH, bw, halfH * 2);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_w - bw/2, _h/2 - (_h*0.03).toNumber(), Graphics.FONT_SMALL, "💧",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(_w - bw/2, _h/2 + (_h*0.035).toNumber(), Graphics.FONT_SMALL, ">",
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

        // подписи прижаты к центру экрана:
        // верхние (+1,+0.1) — в нижнюю треть своей зоны; нижние (-1,-0.1,OK) — в верхнюю треть
        var topY = (rh * 0.72).toNumber();      // нижняя треть верхнего ряда
        var botY = (rh + rh * 0.28).toNumber(); // верхняя треть нижнего ряда

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw/2,      topY, Graphics.FONT_MEDIUM, "+1",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(2*cw+cw/2, topY, Graphics.FONT_MEDIUM, "+0,1",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(cw/2,      botY, Graphics.FONT_MEDIUM, "-1",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(2*cw+cw/2, botY, Graphics.FONT_MEDIUM, "-0,1",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw+cw/2, botY, Graphics.FONT_MEDIUM, "OK",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // значение белым на чёрном — тоже в нижнюю треть верхнего ряда (к центру)
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cw+cw/2, topY, Graphics.FONT_NUMBER_MEDIUM, valStr(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // левый край — возврат 🔁 < (доли вместо пикселей)
        var bw = zoneW();
        var halfH = (_h * 0.10).toNumber();
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, rh - halfH, bw, halfH * 2);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(bw/2, rh - (_h*0.03).toNumber(), Graphics.FONT_SMALL, "🔁",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(bw/2, rh + (_h*0.035).toNumber(), Graphics.FONT_SMALL, "<",
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
