import XCTest
@testable import LiteMuxCore

final class MetricLineParserTests: XCTestCase {
    private func record(_ line: String, _ parser: inout MetricLineParser) -> MetricRecord? {
        if case .record(let r)? = parser.parse(line) { return r }
        return nil
    }

    private func record(_ line: String) -> MetricRecord? {
        var p = MetricLineParser()
        return record(line, &p)
    }

    func testPlainPrint() throws {
        let r = try XCTUnwrap(record("Epoch  7/40  loss=0.378  acc=0.920  lr=3e-4"))
        XCTAssertEqual(r.epoch, 7)
        XCTAssertEqual(r.epochTotal, 40)
        XCTAssertEqual(r.values["loss"], 0.378)
        XCTAssertEqual(r.values["acc"], 0.920)
        XCTAssertEqual(r.values["lr"], 3e-4)
    }

    func testKerasHeaderAndBar() throws {
        let header = try XCTUnwrap(record("Epoch 3/10"))
        XCTAssertEqual(header.epoch, 3)
        XCTAssertEqual(header.epochTotal, 10)
        XCTAssertTrue(header.values.isEmpty)

        let bar = try XCTUnwrap(record("1875/1875 [==============================] - 5s 3ms/step - loss: 0.2964 - accuracy: 0.9129 - val_loss: 0.1500 - val_accuracy: 0.9550"))
        XCTAssertEqual(bar.step, 1875)
        XCTAssertEqual(bar.stepTotal, 1875)
        XCTAssertEqual(bar.values["loss"], 0.2964)
        XCTAssertEqual(bar.values["val_accuracy"], 0.9550)
        XCTAssertNil(bar.epoch)
    }

    func testTqdmPostfix() throws {
        let r = try XCTUnwrap(record("Epoch 2: 45%|████▌     | 450/1000 [00:10<00:12, 44.1it/s, v_num=0, train_loss=0.234, train_acc=0.91]"))
        XCTAssertEqual(r.epoch, 2)
        XCTAssertEqual(r.step, 450)
        XCTAssertEqual(r.stepTotal, 1000)
        XCTAssertEqual(r.values["train_loss"], 0.234)
        XCTAssertNil(r.values["v_num"])
    }

    func testHuggingFaceDict() throws {
        let r = try XCTUnwrap(record("{'loss': 0.4567, 'grad_norm': 1.23, 'learning_rate': 4.5e-05, 'epoch': 0.5}"))
        XCTAssertEqual(r.epoch, 0.5)
        XCTAssertEqual(r.values["loss"], 0.4567)
        XCTAssertEqual(r.values["learning_rate"], 4.5e-05)
        XCTAssertEqual(r.values["grad_norm"], 1.23)
    }

    func testMMDetection() throws {
        let r = try XCTUnwrap(record("2026/11/13 10:00:01 - mmengine - INFO - Epoch(train)  [3][ 50/7330]  lr: 2.0000e-02  eta: 1 day, 2:03:04  time: 0.5412  data_time: 0.0101  memory: 9876  loss: 1.2345  loss_cls: 0.6000  loss_bbox: 0.4000"))
        XCTAssertEqual(r.epoch, 3)
        XCTAssertEqual(r.step, 50)
        XCTAssertEqual(r.stepTotal, 7330)
        XCTAssertEqual(r.values["loss_cls"], 0.6)
        XCTAssertEqual(r.values["lr"], 0.02)
        XCTAssertNil(r.values["time"])
        XCTAssertNil(r.values["memory"])
        XCTAssertNil(r.values["data_time"])
    }

    func testDetectron2StepOnly() throws {
        // No epoch: only kept because it carries metrics.
        let r = try XCTUnwrap(record("[11/13 10:00:01 d2.utils.events]:  eta: 0:12:34  iter: 199  total_loss: 1.234  loss_cls: 0.5  time: 0.4  lr: 0.0002  max_mem: 5000M"))
        XCTAssertEqual(r.step, 199)
        XCTAssertEqual(r.values["total_loss"], 1.234)
        XCTAssertNil(r.values["max_mem"])
    }

    func testUltralyticsTable() throws {
        var p = MetricLineParser()
        XCTAssertNil(p.parse("      Epoch    GPU_mem   box_loss   cls_loss   dfl_loss  Instances       Size"))
        let r = try XCTUnwrap(record("      12/100      3.21G      1.234     0.8765      1.102         45        640: 100%|██████████| 59/59 [00:10<00:00,  5.61it/s]", &p))
        XCTAssertEqual(r.epoch, 12)
        XCTAssertEqual(r.epochTotal, 100)
        XCTAssertEqual(r.values["box_loss"], 1.234)
        XCTAssertEqual(r.values["dfl_loss"], 1.102)
        XCTAssertNil(r.values["GPU_mem"])
        XCTAssertEqual(r.step, 59)

        XCTAssertNil(p.parse("                 Class     Images  Instances      Box(P          R      mAP50  mAP50-95): 100%|██████████| 4/4 [00:01<00:00]"))
        let v = try XCTUnwrap(record("                   all        128        929      0.642      0.533      0.612      0.451", &p))
        XCTAssertTrue(v.isTableRow)
        XCTAssertEqual(v.values["mAP50"], 0.612)
        XCTAssertEqual(v.values["mAP50-95"], 0.451)
        XCTAssertNil(v.values["P"])
    }

    func testNaNAndSignals() throws {
        let r = try XCTUnwrap(record("step 1200 | loss nan | lr 1e-4"))
        XCTAssertTrue(r.values["loss"]?.isNaN ?? false)
        XCTAssertEqual(r.values["lr"], 1e-4)

        var p = MetricLineParser()
        XCTAssertEqual(p.parse("Traceback (most recent call last):"), .signal(.crash("Python 抛出异常")))
        XCTAssertEqual(p.parse("torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 2.00 GiB"), .signal(.crash("CUDA out of memory")))
        XCTAssertEqual(p.parse("Killed"), .signal(.crash("进程被系统杀死 (Killed)")))
        XCTAssertEqual(p.parse("Training complete in 1h 12m"), .signal(.finished))
    }

    func testIgnoresNoise() {
        XCTAssertNil(record("goudu@lab1:~/exp$ python train.py --epochs 40 --lr 3e-4"))
        XCTAssertNil(record("Saved checkpoint to runs/exp/epoch_12.pth"))
        XCTAssertNil(record("[lm_1] 0:zsh*  \"lab1\" 02:12 13-Nov-26"))
        XCTAssertNil(record("drwxr-xr-x  5 goudu staff  160 Nov 13 10:00 data"))
        XCTAssertNil(record("confidence=0.5 seed=42 num_workers: 8"))
    }

    func testMetricNames() {
        XCTAssertTrue(MetricLineParser.isMetricName("val/mIoU"))
        XCTAssertTrue(MetricLineParser.isMetricName("top1"))
        XCTAssertTrue(MetricLineParser.isMetricName("val_f1"))
        XCTAssertFalse(MetricLineParser.isMetricName("gradient_accumulation_steps"))
        XCTAssertFalse(MetricLineParser.isMetricName("train_runtime"))
        XCTAssertTrue(MetricLineParser.lowerIsBetter("val_loss"))
        XCTAssertFalse(MetricLineParser.lowerIsBetter("val_acc"))
        XCTAssertTrue(MetricLineParser.isLearningRate("lr"))
        XCTAssertTrue(MetricLineParser.isLearningRate("learning_rate"))
    }
}

final class TrainingTrackerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func tracker() -> TrainingTracker {
        TrainingTracker(now: { [unowned self] in self.clock })
    }

    private func lines(_ range: ClosedRange<Int>, total: Int = 40) -> [String] {
        range.map { String(format: "Epoch %2ld/%ld  loss=%.3f  acc=0.9%02ld  lr=3e-4", $0, total, 2.0 / Double($0), $0) }
    }

    func testRedrawsDoNotDuplicate() throws {
        let t = tracker()
        t.ingest(lines: lines(1...10))
        // tmux reattach redraws the same screen, overlapping the old lines.
        t.ingest(lines: lines(5...12))
        let run = try XCTUnwrap(t.current)
        XCTAssertEqual(run.series(named: "loss")?.points.count, 12)
        XCTAssertEqual(run.series(named: "loss")?.points.map(\.x), (1...12).map(Double.init))
        XCTAssertEqual(run.epoch, 12)
        XCTAssertEqual(run.fraction ?? 0, 12.0 / 40, accuracy: 1e-9)
        XCTAssertEqual(run.primary?.name, "loss")
        XCTAssertEqual(run.orderedSeries.map(\.name), ["loss", "acc", "lr"])
        XCTAssertEqual(run.series(named: "loss")?.trend, -1)
        XCTAssertEqual(run.series(named: "loss")?.best ?? 0, 2.0 / 12, accuracy: 1e-3)
    }

    func testInPlaceProgressReplacesPoint() throws {
        let t = tracker()
        t.ingest(lines: ["Epoch 1: 10%| | 100/1000 [00:01<00:09, loss=1.00]"])
        t.ingest(lines: ["Epoch 1: 10%| | 100/1000 [00:01<00:09, loss=0.90]"])
        t.ingest(lines: ["Epoch 1: 20%|█ | 200/1000 [00:02<00:08, loss=0.80]"])
        let s = try XCTUnwrap(t.current?.series(named: "loss"))
        XCTAssertEqual(s.points.count, 2)
        XCTAssertEqual(s.points[0].y, 0.90)
        XCTAssertEqual(s.points[1].x, 0.2, accuracy: 1e-9)
    }

    func testFinishAndRestartKeepsGhost() throws {
        let t = tracker()
        var events = t.ingest(lines: lines(1...39))
        XCTAssertEqual(events.first, .started)
        clock += 60
        events = t.ingest(lines: lines(40...40))
        XCTAssertEqual(events, [.finished])
        XCTAssertEqual(t.current?.status, .finished)

        events = t.ingest(lines: ["Epoch  1/40  loss=2.500  acc=0.100  lr=1e-3"])
        XCTAssertEqual(events, [.started])
        XCTAssertEqual(t.current?.series(named: "loss")?.points.count, 1)
        XCTAssertEqual(t.previous?.series(named: "loss")?.points.count, 40)
    }

    func testDivergenceAndCrash() {
        let t = tracker()
        t.ingest(lines: lines(1...5))
        XCTAssertEqual(t.ingest(lines: ["Epoch  6/40  loss=nan  acc=0.100  lr=3e-4"]), [.diverged(metric: "loss")])
        XCTAssertEqual(t.current?.status, .diverged(metric: "loss"))

        let u = tracker()
        u.ingest(lines: lines(1...5))
        XCTAssertEqual(u.ingest(lines: ["Traceback (most recent call last):", "  File \"train.py\", line 3", "torch.OutOfMemoryError: CUDA out of memory."]),
                       [.crashed(reason: "Python 抛出异常")])
        // A traceback with no run in progress is not news.
        XCTAssertEqual(tracker().ingest(lines: ["Traceback (most recent call last):"]), [])
    }

    func testKerasBarsBelongToAnnouncedEpoch() throws {
        let t = tracker()
        t.ingest(lines: ["Epoch 1/2", "1875/1875 [==============================] - 5s 3ms/step - loss: 0.30 - accuracy: 0.91",
                         "Epoch 2/2", "1875/1875 [==============================] - 5s 3ms/step - loss: 0.20 - accuracy: 0.94"])
        let run = try XCTUnwrap(t.current)
        XCTAssertEqual(run.series(named: "loss")?.points.map(\.x), [1, 2])
        XCTAssertEqual(run.status, .finished)
    }

    func testHuggingFaceFractionalEpochs() throws {
        let t = tracker()
        t.ingest(lines: ["{'loss': 0.9, 'learning_rate': 5e-05, 'epoch': 0.25}", "{'loss': 0.7, 'learning_rate': 4e-05, 'epoch': 0.5}"])
        let s = try XCTUnwrap(t.current?.series(named: "loss"))
        XCTAssertEqual(s.points.map(\.x), [0.25, 0.5])
    }

    func testEta() throws {
        let t = tracker()
        t.ingest(lines: lines(1...10))
        clock += 100
        t.ingest(lines: lines(11...20))
        let run = try XCTUnwrap(t.current)
        // 10 epochs in 100 s, 20 to go.
        XCTAssertEqual(run.eta(now: clock) ?? 0, 200, accuracy: 1)
    }

    func testLogicalLinesJoinWrappedRows() {
        let rows = [ScreenRow(text: "Epoch 3/40  loss=0.1"), ScreenRow(text: "23  acc=0.9", isWrapped: true),
                    ScreenRow(text: String(repeating: "x", count: 20)), ScreenRow(text: "tail")]
        XCTAssertEqual(TrainingTracker.logicalLines(rows, cols: 20),
                       ["Epoch 3/40  loss=0.123  acc=0.9", String(repeating: "x", count: 20) + "tail"])
    }

    func testSeriesDecimatesWhenFull() {
        var s = MetricSeries(name: "loss")
        for i in 0..<(MetricSeries.capacity + 1) { s.upsert(MetricPoint(x: Double(i), y: 1)) }
        XCTAssertLessThanOrEqual(s.points.count, MetricSeries.capacity / 2 + 2)
        XCTAssertEqual(s.points.last?.x, Double(MetricSeries.capacity))
    }
}
