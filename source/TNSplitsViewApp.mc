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
    return 11;                      // MIN — шаг строк 30 px на экране 454, как на циферблате (TSV-18)
}

// палитра цветов по индексу (0..6); light — светлая тема (TSV-18): на белом фоне жёлтый и оранжевый
// затемнены, «белый» зоны — чёрный (иначе пропал бы)
function paletteColor(idx, light) {
    if (light) {
        if (idx == 0) { return 0x000000; }   // «белый» → чёрный
        if (idx == 1) { return 0x0086C8; }   // голубой
        if (idx == 2) { return 0x008A00; }   // зелёный
        if (idx == 3) { return 0xB08A00; }   // жёлтый (самый слабый по контрасту на белом)
        if (idx == 4) { return 0xD95F00; }   // оранжевый
        if (idx == 5) { return 0xD00000; }   // красный
        return 0x8A2BE2;                     // 6 = фиолетовый
    }
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
    var _lapCount;         // номер последнего закрытого круга: ранние круги могут уйти из списка (addItem)
    const RESERVE = 1536;  // байт свободной памяти, которые список оставляет полю (addItem, TSV-25)

    // настройки порогов/цветов
    var _thr;              // массив 6 порогов в сек/км (канонический формат)
    var _col;              // массив 7 цветов (0xRRGGBB)
    var _settingsError;    // строка ошибки парсинга или null
    var _useMiles;         // системные единицы: true=мили

    // тема (TSV-18): цвета фона, основного и второстепенного текста, линий; шрифты — Courier Prime Bold
    var _light;            // true = светлая тема (белый фон)
    var _bg; var _fg; var _dim; var _line;
    var _fRow; var _fKey; var _fBig;

    // режим: 0 = список, 1 = ввод лактата
    var _mode;

    // ввод лактата
    var _val10; const MIN10 = 0; const MAX10 = 250;
    var _pending; var _holdSec; var _savedFlash;

    // FIT
    var _fieldRecord;      // числовое record-поле (field 1)
    var _fieldSession;     // итоговое session-поле (field 2): замер, не отстоявший своё в потоке record
    var _timerMs;          // timerTime прошлого compute: не изменился — таймер стоит

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
        _timerMs = 0;
        _lapCount = 0;
        reloadSettings();

        if (_lactateEnabled) {
            _fieldRecord = createField(
                "lactate", 1, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "mmol/L" }
            );
            _fieldSession = createField(
                "lactate_stop", 2, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "mmol/L" }
            );
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

        // тема: 0 = тёмная (по умолчанию, как было), 1 = светлая с белым фоном
        var th = Application.Properties.getValue("theme");
        _light = (th != null && th == 1);
        if (_light) { _bg = 0xFFFFFF; _fg = 0x000000; _dim = 0x6A6A6A; _line = 0xC4C4C4; }
        else        { _bg = 0x000000; _fg = 0xDCDCDC; _dim = 0x7A7A7A; _line = 0x3A3A3A; }

        // цвета 7 зон
        _col = new [7];
        var ckeys = ["color1","color2","color3","color4","color5","color6","color7"];
        for (var j = 0; j < 7; j += 1) {
            var ci = Application.Properties.getValue(ckeys[j]);
            _col[j] = paletteColor((ci == null) ? 0 : ci, _light);
        }
    }

    // цвет по темпу (сек/км) на основе настроенных порогов/цветов
    function colorFor(paceSec) {
        if (paceSec <= 0) { return _fg; }
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
        // виртуальная живая строка: type 0, номер = следующий за последним закрытым, маркер времени -1
        return [ 0, _lapCount + 1, _curLapTime, _curLapDist, _curLapPace, -1 ];
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
        // TSV-18: окно упирается вниз — живой круг в нижней строке, как в макете; раньше живая строка
        // стояла посередине окна, а нижняя половина оставалась пустой
        var rows = rowsForMode(_fontMode);
        var hi = nItems() - 1;
        var lo = rows - 1;
        if (lo > hi) { lo = hi; }
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
        _lapCount += 1;
        addItem([ 0, _lapCount, lapTime, lapDist, pace, tMs ]);
        _lastTimeMs = tMs; _lastDistM = dM;
        // новый круг стартует с нуля
        _curLapTime = 0.0; _curLapDist = 0.0; _curLapPace = 0.0;
        _topIndex = nItems() + 10;
        clampTop();
        WatchUi.requestUpdate();
    }

    // TSV-25: часы с 32 КБ под поле (fēnix 6/6S, fr245, fr645, fr935, fr735xt) дают ему 28,4 КиБ, пустое поле занимает
    // около 25, запись круга — 61 байт, и в симуляторе поле падало при отрисовке на 38–52 кругах. Поэтому новая запись
    // вытесняет самые ранние (в файле тренировки они остаются), пока свободно меньше RESERVE: запас на пик отрисовки
    // (в симуляторе до 0,4 КиБ) и перечитывание настроек. Правило смотрит на память самих часов, а не на число кругов,
    // подобранное в симуляторе; на часах с 64 КБ и больше до вытеснения не доходит.
    function addItem(it) {
        _items.add(it);
        while (_items.size() > 1 && System.getSystemStats().freeMemory < RESERVE) { _items.remove(_items[0]); }
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
        // TSV-31: часы пишут record-точки только при идущем таймере, поэтому 10 с держания
        // считаются, только пока растёт timerTime: замер после «Стоп» ляжет в поток после «Продолжить».
        // Если бегун сохранит тренировку, не продолжив, точек больше не будет — на этот случай замер
        // лежит и в итоговом session-поле, которое часы пишут при сохранении. Когда замер отстоял
        // 10 с в потоке, session-поле обнуляется: ненулевое значение в файле — замер, которого
        // в потоке нет или не хватило (сохранили раньше 10 с); его читать коннектору Runner MCP.
        var tMs = (info != null && info.timerTime != null) ? info.timerTime : _timerMs;
        var running = (tMs != _timerMs);
        _timerMs = tMs;
        _fieldRecord.setData(_pending / 10.0);
        if (_pending != 0) {
            _fieldSession.setData(_pending / 10.0);
            if (running) { _holdSec -= 1; }
            if (_holdSec <= 0) {
                _pending = 0;   // время держания вышло — дальше нули
                _fieldSession.setData(0.0);
            }
        }
    }

    function pageOlder() { _topIndex -= 1; clampTop(); }
    function pageNewer() { _topIndex += 1; clampTop(); }
    function onLayout(dc) {
        _w = dc.getWidth(); _h = dc.getHeight();
        _fRow = WatchUi.loadResource(Rez.Fonts.Row);
        _fKey = WatchUi.loadResource(Rez.Fonts.Key);
        _fBig = WatchUi.loadResource(Rez.Fonts.Big);
    }

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

    // дистанция в строке списка (MIN, MID) не длиннее четырёх знаков: пятый («13.05») доводит её в MIN до колонки
    // времени — «120:0013.05», а строку карусели делает шире круглого экрана. Сотые отбрасываются, а не округляются,
    // как у Garmin; округление сделало бы из 9,996 «10.00». Потолок — круг от 100 км («100.0»). Карточка MAX
    // пишет полную дистанцию (TSV-28)
    function fmtDistRow(meters) {
        var s = fmtDist(meters);
        return s.length() > 4 ? s.substring(0, s.length() - 1) : s;
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
        addItem([ 1, _val10, tMs, 0, 0, tMs ]);
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
        if (_fRow == null) { onLayout(dc); }
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }   // API 3.2+ по документации SDK (TSV-24); has обязателен: fr645, fr935 (3.1) и fr735xt (2.4) его не имеют (TSV-25)
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

    // ——— оформление TSV-18: язык циферблата TN Watch Face ———
    // Один шрифт (Courier Prime Bold трёх размеров, tools/make_fonts.py), цвет несёт только смысл (темп, лактат),
    // остальное — основной и серый текст. Раскладка в пикселях макета 454 (design/mockup.html), sc() переводит её
    // в пиксели экрана. Потолок: DIGIT_H — высоты цифр шрифтов на 454 (вывод make_fonts.py); сменишь размеры шрифтов —
    // поправь и их.
    function sc(v) { return (v * _w / 454.0 + 0.5).toNumber(); }

    // текст по середине цифр: y — середина строки, justify — только по горизонтали
    function txt(dc, x, y, font, s, color, justify) {
        var dh = sc(font == _fBig ? 40 : (font == _fKey ? 23 : 15));
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y + dh / 2 - Graphics.getFontAscent(font), font, s, justify);
    }

    // капля (вместо эмодзи: в Courier Prime его нет): круг снизу и треугольник, касательный к нему, сверху
    function drop(dc, x, y, h, color) {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y + h * 0.25, h * 0.35);
        dc.fillPolygon([ [x, y - h * 0.5], [x - h * 0.309, y + h * 0.087], [x + h * 0.309, y + h * 0.087] ]);
    }

    // стрелка-уголок вправо (dir = 1) или влево (dir = -1)
    function chevron(dc, x, y, dir, color) {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sc(3));
        dc.drawLine(x - sc(4) * dir, y - sc(8), x + sc(4) * dir, y);
        dc.drawLine(x + sc(4) * dir, y, x - sc(4) * dir, y + sc(8));
        dc.setPenWidth(1);
    }

    function drawList(dc) {
        clampTop();
        dc.setColor(_fg, _bg); dc.clear();

        if (_tapFlash > 0) {
            dc.setColor(_dim, Graphics.COLOR_TRANSPARENT);
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
        } else {                                  // MIN — 11 строк
            var rows = rowsForMode(_fontMode);
            var pitch = sc(30);
            var y0 = _h / 2 - pitch * (rows - 1) / 2;
            var i = 0;
            while (i < rows) {
                var idx = _topIndex - (rows - 1 - i);
                if (idx >= 0 && idx < nItems()) {
                    var yc = y0 + i * pitch;
                    if (idx == nItems() - 1) {      // линия над живым кругом
                        dc.setColor(_line, Graphics.COLOR_TRANSPARENT);
                        dc.setPenWidth(2);
                        var ly = yc - pitch / 2;
                        dc.drawLine(sc(58), ly, _lactateEnabled ? _w - zoneW() - sc(8) : _w - sc(58), ly);
                        dc.setPenWidth(1);
                    }
                    drawRow(dc, itemAt(idx), yc);
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

    // центр строк на средней полосе экрана (центр карусели, карточка) с учётом правой зоны переключения
    function listCx() {
        if (_lactateEnabled) {
            var bw = zoneW();
            return (_w - bw) / 2 - 2;   // -2px: отодвинуть текст от зоны, чтобы цифры не прилипали
        }
        return _w / 2;
    }

    // строка MIN: колонки по правому краю — номер, время, дистанция, темп; замер лактата — в тех же колонках
    function drawRow(dc, it, y) {
        // по центру экрана и при включённом лактате: сдвинутый влево от зоны переключения список срезал номер
        // в верхней и нижней строке, а темп и по центру остаётся в 15–24 px от плашки зоны (TSV-27)
        var cx = _w / 2;
        var right = Graphics.TEXT_JUSTIFY_RIGHT;
        if (it[0] == 0) {
            var live = (it[5] == -1);
            var sec = it[2];
            // время от 10:00 доходит до номера и слипается с ним («10152:30»), а сдвинуть номер некуда: у крайних
            // строк он уже у края круглого экрана. Номер такого круга виден в MID и MAX (TSV-26)
            if (sec < 600) {
                txt(dc, cx - sc(104), y, _fRow, it[1].format("%d"), _dim, right);
            }
            txt(dc, cx - sc(22), y, _fRow, fmtTime(sec), _fg, right);
            txt(dc, cx + sc(62), y, _fRow, fmtDistRow(it[3]), _dim, right);
            txt(dc, cx + sc(150), y, _fRow, fmtPaceU(it[4]), live ? _fg : colorFor(it[4]), right);
        } else {
            var c = paletteColor(1, _light);
            drop(dc, cx - sc(118), y, sc(22), c);
            txt(dc, cx - sc(22), y, _fRow, valOf(it[1]), c, right);
            txt(dc, cx + sc(150), y, _fRow, fmtClock(it[2]), _dim, right);
        }
    }

    function valOf(v10) { return (v10/10).format("%d") + "," + (v10%10).format("%d"); }

    // MID-карусель: 5 строк, центр (_topIndex) — активный/крупный, к краям мельче.
    // Центрируем имеющиеся: активная запись всегда по центру, пустые слоты пусты.
    function drawCarousel(dc) {
        var center = _topIndex;
        // крайние строки не выше 25% высоты: выше строка сотого круга ультра «100  10:30  1.00  10:30» шире круглого
        // экрана (самому тесному, 360, нужно 23,8%); шаг между строками ровный. Круг от 100 минут или от 10 км не влезет
        // и так (TSV-27)
        var ys = [ _h * 0.25, _h * 0.375, _h * 0.50, _h * 0.625, _h * 0.75 ];
        var off = [ -2, -1, 0, 1, 2 ];
        for (var i = 0; i < 5; i += 1) {
            var idx = center + off[i];
            if (idx >= 0 && idx < nItems()) {
                var y = ys[i].toNumber();
                // линия над живым треком (последний индекс)
                if (idx == nItems() - 1) {
                    dc.setColor(_line, Graphics.COLOR_TRANSPARENT);
                    dc.setPenWidth(2);
                    var lx0 = (_w * 0.12).toNumber();
                    var lx1 = _lactateEnabled ? (_w * 0.76).toNumber() : (_w * 0.88).toNumber();
                    var ly = ((ys[i - 1] + ys[i]) / 2).toNumber();   // живой круг не выше центра: i >= 2
                    dc.drawLine(lx0, ly, lx1, ly);
                    dc.setPenWidth(1);
                }
                drawRowFont(dc, itemAt(idx), y, off[i] == 0 ? _fKey : _fRow, off[i] == 0);
            }
        }
    }

    // строка карусели одним блоком по центру; active=true — центр, крупнее и без номера отрезка (избыточен)
    function drawRowFont(dc, it, y, font, active) {
        // плашка зоны переключения — только на средней полосе, поэтому от неё уходит одна центральная строка;
        // остальные, сдвинутые влево, вылезали за левый край круга (TSV-27)
        var cx = active ? listCx() : _w / 2;
        if (it[0] == 0) {
            var head = fmtTime(it[2]) + "  " + fmtDistRow(it[3]) + "  ";
            if (!active) { head = it[1].format("%d") + "  " + head; }
            var pace = fmtPaceU(it[4]);
            var x = cx - (dc.getTextWidthInPixels(head, font) + dc.getTextWidthInPixels(pace, font)) / 2;
            txt(dc, x, y, font, head, _fg, Graphics.TEXT_JUSTIFY_LEFT);
            txt(dc, x + dc.getTextWidthInPixels(head, font), y, font, pace,
                it[5] == -1 ? _fg : colorFor(it[4]), Graphics.TEXT_JUSTIFY_LEFT);
        } else {
            var c = paletteColor(1, _light);
            var v = valOf(it[1]);
            var clock = "  " + fmtClock(it[2]);
            var dh = sc(active ? 30 : 22);
            var x = cx - (dh + dc.getTextWidthInPixels(v, font) + dc.getTextWidthInPixels(clock, font)) / 2;
            drop(dc, x + dh / 2, y, dh, c);
            txt(dc, x + dh, y, font, v, c, Graphics.TEXT_JUSTIFY_LEFT);
            txt(dc, x + dh + dc.getTextWidthInPixels(v, font), y, font, clock, _dim, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    // MAX-карточка: один круг или замер крупно
    function drawCard(dc, it) {
        var cx = listCx();
        var mid = Graphics.TEXT_JUSTIFY_CENTER;
        if (it[0] == 0) {
            txt(dc, cx, (_h * 0.20).toNumber(), _fRow, it[1].format("%d"), _dim, mid);
            txt(dc, cx, (_h * 0.40).toNumber(), _fBig, fmtTime(it[2]), _fg, mid);
            txt(dc, cx, (_h * 0.62).toNumber(), _fKey, fmtDist(it[3]) + " " + distUnit(), _fg, mid);
            txt(dc, cx, (_h * 0.78).toNumber(), _fKey, fmtPaceU(it[4]) + " /" + distUnit(),
                it[5] == -1 ? _fg : colorFor(it[4]), mid);
        } else {
            var c = paletteColor(1, _light);
            drop(dc, cx, (_h * 0.22).toNumber(), sc(40), c);
            txt(dc, cx, (_h * 0.40).toNumber(), _fBig, valOf(it[1]), c, mid);
            txt(dc, cx, (_h * 0.62).toNumber(), _fKey, fmtClock(it[2]), _dim, mid);
        }
    }

    function drawRightSwitch(dc) {
        var bw = zoneW();
        // компактная плашка по центру правого края (касание зарезервировано на всю высоту в handleListTap)
        dc.setColor(_line, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sc(3));
        dc.drawRoundedRectangle(_w - bw + sc(14), _h / 2 - sc(45), bw - sc(14) + sc(4), sc(90), sc(16));
        dc.setPenWidth(1);
        drop(dc, _w - bw / 2 + sc(7), _h / 2 - sc(16), sc(24), _fg);
        chevron(dc, _w - bw / 2 + sc(7), _h / 2 + sc(24), 1, _fg);
    }

    // ввод: зоны те же (3×2), но без заливок — линии, «+»/«-» цветом текста, OK — единственная плотная плашка
    function drawInput(dc) {
        var cw = _w/3; var rh = _h/2;
        dc.setColor(_fg, _bg); dc.clear();

        dc.setColor(_line, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(cw, sc(60), cw, _h - sc(60));
        dc.drawLine(2*cw, sc(60), 2*cw, _h - sc(60));
        dc.drawLine(sc(40), rh, _w - sc(40), rh);
        dc.setPenWidth(1);

        // подписи прижаты к центру экрана: верхние (+1,+0,1) — в нижнюю треть своей зоны, нижние — в верхнюю
        var topY = (rh * 0.72).toNumber();
        var botY = (rh + rh * 0.28).toNumber();
        var up = paletteColor(2, _light);
        var down = paletteColor(5, _light);
        var mid = Graphics.TEXT_JUSTIFY_CENTER;
        txt(dc, cw/2 + sc(10), topY, _fKey, "+1", up, mid);
        txt(dc, 2*cw + cw/2 - sc(10), topY, _fKey, "+0,1", up, mid);
        txt(dc, cw/2 + sc(10), botY, _fKey, "-1", down, mid);
        txt(dc, 2*cw + cw/2 - sc(10), botY, _fKey, "-0,1", down, mid);

        // значение — в нижнюю треть верхнего ряда (к центру), над ним капля
        drop(dc, cw + cw/2, (rh * 0.30).toNumber(), sc(26), paletteColor(1, _light));
        txt(dc, cw + cw/2, topY - sc(4), _fBig, valStr(), _fg, mid);

        // OK — светлая (в тёмной теме) или чёрная (в светлой) плашка
        dc.setColor(_fg, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cw + sc(14), rh + sc(14), cw - sc(28), (rh * 0.5).toNumber(), sc(24));
        txt(dc, cw + cw/2, rh + sc(14) + (rh * 0.25).toNumber(), _fKey, "OK", _bg, mid);

        // левый край — возврат: капля и стрелка влево
        var bw = zoneW();
        dc.setColor(_line, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sc(3));
        dc.drawRoundedRectangle(-sc(20), rh - sc(45), bw + sc(6), sc(90), sc(16));
        dc.setPenWidth(1);
        chevron(dc, bw / 2 - sc(7), rh - sc(24), -1, _fg);
        drop(dc, bw / 2 - sc(7), rh + sc(16), sc(24), _fg);
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
