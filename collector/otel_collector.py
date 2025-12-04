from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SimpleSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource

def setup_telemetry(service_name: str, endpoint: str = "http://otel-collector:4317"):
    """
    Configura o OpenTelemetry para enviar traces para o Collector.
    """
    resource = Resource.create({"service.name": service_name})
    
    trace.set_tracer_provider(TracerProvider(resource=resource))
    
    otlp_exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    
    # Usar SimpleSpanProcessor para envio imediato (melhor para debug/testes curtos)
    span_processor = SimpleSpanProcessor(otlp_exporter)
    
    trace.get_tracer_provider().add_span_processor(span_processor)
    
    return trace.get_tracer(__name__)
