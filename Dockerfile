FROM python:3.10-slim

WORKDIR /app

# Instalar dependências do sistema (incluindo cliente SSH)
RUN apt-get update && apt-get install -y \
    sshpass \
    openssh-client \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Copiar requirements e instalar
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# O código será montado via volume no docker-compose para desenvolvimento
# Mas copiamos aqui para garantir que a imagem funcione standalone
COPY . .

CMD ["uvicorn", "src.app.main:app", "--host", "0.0.0.0", "--port", "8000"]
