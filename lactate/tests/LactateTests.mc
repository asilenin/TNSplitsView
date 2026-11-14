import Toybox.Test;

(:test)
function entryAndCap(logger) {
    _bindFit = false;
    var v = new LactateView();
    v._val10 = 250;
    v.bump(1);
    Test.assertEqual(v._val10, 250);
    v._val10 = 0;
    v.bump(-1);
    Test.assertEqual(v._val10, 0);
    v._val10 = 20;
    v.confirm();
    Test.assertEqual(v._mode, 0);
    Test.assertEqual(v._pending, 20);
    Test.assertEqual(v._holdSec, 10);
    Test.assertEqual(v._samples.size(), 1);
    Test.assertEqual(v._samples[0][0], 20);
    Test.assertEqual(v.fmtClock(0), "0:00");
    Test.assertEqual(v.fmtClock(65000), "1:05");
    Test.assertEqual(v.fmtClock(3661000), "1:01:01");
    for (var i = 0; i <= SAMPLE_CAP; i += 1) {
        v._val10 = i;
        v.confirm();
    }
    Test.assertEqual(v._samples.size(), SAMPLE_CAP);
    Test.assertEqual(v._samples[0][0], 1);
    Test.assertEqual(v._samples[SAMPLE_CAP - 1][0], SAMPLE_CAP);
    Test.assertEqual(v._pending, SAMPLE_CAP);
    return true;
}
