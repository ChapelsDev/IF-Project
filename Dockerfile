FROM python:3.10-slim

# Instalar dependências do sistema (SSH client é fundamental para o chaos_manager)
RUN apt-get update && apt-get install -y \
    openssh-client \
    iproute2 \
    iputils-ping \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copiar requirements e instalar
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiar o código fonte
COPY . .

# Expor a porta da API
EXPOSE 8000

# Comando de entrada (usando o loop asyncio para evitar aquele erro anterior)
CMD ["uvicorn", "api.server:app", "--host", "0.0.0.0", "--port", "8000", "--loop", "asyncio"]
