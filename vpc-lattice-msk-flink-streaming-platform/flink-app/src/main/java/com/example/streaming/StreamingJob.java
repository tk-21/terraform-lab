package com.example.streaming;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.functions.AggregateFunction;
import org.apache.flink.api.common.functions.FlatMapFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.api.java.tuple.Tuple3;
import org.apache.flink.connector.file.sink.FileSink;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.core.fs.Path;
import org.apache.flink.formats.parquet.avro.AvroParquetWriters;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.sink.filesystem.bucketassigners.DateTimeBucketAssigner;
import org.apache.flink.streaming.api.functions.sink.filesystem.rollingpolicies.OnCheckpointRollingPolicy;
import org.apache.flink.streaming.api.windowing.assigners.TumblingProcessingTimeWindows;
import org.apache.flink.streaming.api.windowing.time.Time;
import org.apache.flink.util.Collector;

import java.util.Optional;
import java.util.Properties;

public class StreamingJob {

    public static class ServiceMetrics {
        public String service_name;
        public long total_count;
        public long error_count;
        public double avg_latency_ms;
        public String window_start;
        public String window_end;

        public ServiceMetrics() {}
    }

    static class Accumulator {
        String serviceName = "";
        long count = 0L;
        long errorCount = 0L;
        double totalLatency = 0.0;
    }

    static class ServiceMetricsAggregateFunction
            implements AggregateFunction<Tuple3<String, Double, Boolean>, Accumulator, ServiceMetrics> {

        @Override
        public Accumulator createAccumulator() {
            return new Accumulator();
        }

        @Override
        public Accumulator add(Tuple3<String, Double, Boolean> value, Accumulator accumulator) {
            accumulator.serviceName = value.f0;
            accumulator.count++;
            accumulator.errorCount += value.f2 ? 1L : 0L;
            accumulator.totalLatency += value.f1;
            return accumulator;
        }

        @Override
        public ServiceMetrics getResult(Accumulator accumulator) {
            ServiceMetrics metrics = new ServiceMetrics();
            metrics.service_name = accumulator.serviceName;
            metrics.total_count = accumulator.count;
            metrics.error_count = accumulator.errorCount;
            metrics.avg_latency_ms = accumulator.count > 0
                    ? accumulator.totalLatency / accumulator.count
                    : 0.0;
            metrics.window_start = "N/A";
            metrics.window_end = "N/A";
            return metrics;
        }

        @Override
        public Accumulator merge(Accumulator a, Accumulator b) {
            a.serviceName = b.serviceName.isEmpty() ? a.serviceName : b.serviceName;
            a.count += b.count;
            a.errorCount += b.errorCount;
            a.totalLatency += b.totalLatency;
            return a;
        }
    }

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);

        String checkpointPath = System.getenv("CHECKPOINT_S3_PATH");
        if (checkpointPath \!= null && \!checkpointPath.isEmpty()) {
            env.getCheckpointConfig().setCheckpointStorage(checkpointPath);
        }

        Properties kafkaProps = new Properties();
        kafkaProps.setProperty("security.protocol", "SASL_SSL");
        kafkaProps.setProperty("sasl.mechanism", "OAUTHBEARER");
        kafkaProps.setProperty("sasl.jaas.config",
                "software.amazon.msk.auth.iam.IAMLoginModule required;");
        kafkaProps.setProperty("sasl.client.callback.handler.class",
                "software.amazon.msk.auth.iam.IAMClientCallbackHandler");

        String bootstrapServers = System.getenv("BOOTSTRAP_SERVERS");
        String kafkaTopic = Optional.ofNullable(System.getenv("KAFKA_TOPIC"))
                .orElse("streaming-events");

        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers(bootstrapServers)
                .setTopics(kafkaTopic)
                .setGroupId("flink-streaming-consumer")
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .setStartingOffsets(OffsetsInitializer.latest())
                .setProperties(kafkaProps)
                .build();

        DataStream<String> rawStream = env.fromSource(
                kafkaSource,
                WatermarkStrategy.noWatermarks(),
                "Kafka Source"
        );

        DataStream<Tuple3<String, Double, Boolean>> parsedStream = rawStream
                .flatMap(new FlatMapFunction<String, Tuple3<String, Double, Boolean>>() {
                    @Override
                    public void flatMap(String value, Collector<Tuple3<String, Double, Boolean>> out) {
                        try {
                            JsonObject json = JsonParser.parseString(value).getAsJsonObject();
                            String serviceName = json.get("service_name").getAsString();
                            double latencyMs = json.get("latency_ms").getAsDouble();
                            String status = json.get("status").getAsString();
                            boolean isError = "error".equalsIgnoreCase(status);
                            out.collect(Tuple3.of(serviceName, latencyMs, isError));
                        } catch (Exception e) {
                            // skip malformed records
                        }
                    }
                });

        DataStream<ServiceMetrics> aggregated = parsedStream
                .keyBy(t -> t.f0)
                .window(TumblingProcessingTimeWindows.of(Time.seconds(60)))
                .aggregate(new ServiceMetricsAggregateFunction());

        String outputPath = System.getenv("OUTPUT_S3_PATH");

        FileSink<ServiceMetrics> fileSink = FileSink
                .<ServiceMetrics>forBulkFormat(
                        new Path(outputPath),
                        AvroParquetWriters.forReflectRecord(ServiceMetrics.class)
                )
                .withBucketAssigner(
                        new DateTimeBucketAssigner<>("'year='yyyy/'month='MM/'day='dd/'hour='HH")
                )
                .withRollingPolicy(OnCheckpointRollingPolicy.build())
                .build();

        aggregated.sinkTo(fileSink);

        env.execute("Streaming MSK to S3 Job");
    }
}
