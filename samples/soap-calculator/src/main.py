import logging
from spyne import Application, Service, rpc, Integer, Float
from spyne.protocol.soap import Soap11
from spyne.server.wsgi import WsgiApplication
from gunicorn.app.base import BaseApplication

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class CalculatorService(Service):
    """A simple SOAP Calculator service with four operations."""

    @rpc(Integer, Integer, _returns=Integer)
    def Add(ctx, a, b):
        logger.info("Add(%s, %s)", a, b)
        return a + b

    @rpc(Integer, Integer, _returns=Integer)
    def Subtract(ctx, a, b):
        logger.info("Subtract(%s, %s)", a, b)
        return a - b

    @rpc(Integer, Integer, _returns=Integer)
    def Multiply(ctx, a, b):
        logger.info("Multiply(%s, %s)", a, b)
        return a * b

    @rpc(Integer, Integer, _returns=Float)
    def Divide(ctx, a, b):
        logger.info("Divide(%s, %s)", a, b)
        if b == 0:
            return float('inf')
        return a / b


application = Application(
    [CalculatorService],
    tns='http://calculator.example.com',
    in_protocol=Soap11(validator='lxml'),
    out_protocol=Soap11(),
)

wsgi_app = WsgiApplication(application)

class _App(BaseApplication):
    def __init__(self, app, options=None):
        self.options = options or {}
        self.application = app
        super().__init__()

    def load_config(self):
        for key, value in self.options.items():
            if key in self.cfg.settings and value is not None:
                self.cfg.set(key.lower(), value)

    def load(self):
        return self.application


if __name__ == '__main__':
    logger.info("SOAP Calculator starting on port 8000")
    logger.info("WSDL available at http://0.0.0.0:8000/?wsdl")
    _App(wsgi_app, {'bind': '0.0.0.0:8000', 'workers': 4}).run()
