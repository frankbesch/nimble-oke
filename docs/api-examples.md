# NVIDIA NIM API Examples

> **📖 Reading time:** 9 minutes  
> **🔗 API reference** - Copy/paste examples for testing

Comprehensive API examples for testing and using NVIDIA NIM with Meta Llama 3.1 8B model.

## Setup

### Get Your Endpoint

```bash
# From service
export NIM_ENDPOINT=http://$(kubectl get svc nvidia-nim -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8000

# Or use port-forward if LoadBalancer not available
kubectl port-forward svc/nvidia-nim 8000:8000 &
export NIM_ENDPOINT=http://localhost:8000
```

### Verify Connection

```bash
curl $NIM_ENDPOINT/v1/health/ready
```

Expected: `{"status":"ready"}`

## API Endpoints

### Health Checks

**Readiness Check**

```bash
curl $NIM_ENDPOINT/v1/health/ready
```

Response:
```json
{
  "status": "ready"
}
```

**Liveness Check**

```bash
curl $NIM_ENDPOINT/v1/health/live
```

Response:
```json
{
  "status": "alive"
}
```

### List Models

```bash
curl $NIM_ENDPOINT/v1/models
```

Response:
```json
{
  "object": "list",
  "data": [
    {
      "id": "meta/llama-3.1-8b-instruct",
      "object": "model",
      "created": 1728500000,
      "owned_by": "meta"
    }
  ]
}
```

## Chat Completions API

### Basic Chat

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "user",
        "content": "What is the capital of France?"
      }
    ],
    "max_tokens": 50
  }'
```

Response:
```json
{
  "id": "chatcmpl-xxxxx",
  "object": "chat.completion",
  "created": 1728500123,
  "model": "meta/llama-3.1-8b-instruct",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "The capital of France is Paris."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 15,
    "completion_tokens": 8,
    "total_tokens": 23
  }
}
```

### Conversational Chat (with System Prompt)

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "You are a helpful technical expert specializing in cloud computing."
      },
      {
        "role": "user",
        "content": "What is Kubernetes?"
      }
    ],
    "max_tokens": 150,
    "temperature": 0.7
  }' | jq
```

### Multi-turn Conversation

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "You are a technical expert."
      },
      {
        "role": "user",
        "content": "What is NVIDIA NIM?"
      },
      {
        "role": "assistant",
        "content": "NVIDIA NIM is a set of optimized inference microservices for deploying AI models."
      },
      {
        "role": "user",
        "content": "What are its benefits?"
      }
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }' | jq
```

## Parameter Control

### Temperature (Creativity Control)

**Low temperature (0.1) - More deterministic:**

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {"role": "user", "content": "Write a haiku about AI"}
    ],
    "temperature": 0.1,
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'
```

**High temperature (1.5) - More creative:**

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {"role": "user", "content": "Write a haiku about AI"}
    ],
    "temperature": 1.5,
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'
```

### Top-p (Nucleus Sampling)

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {"role": "user", "content": "Explain machine learning"}
    ],
    "top_p": 0.9,
    "temperature": 0.8,
    "max_tokens": 100
  }' | jq
```

### Presence and Frequency Penalty

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {"role": "user", "content": "List cloud providers"}
    ],
    "presence_penalty": 0.6,
    "frequency_penalty": 0.3,
    "max_tokens": 100
  }' | jq
```

### Stop Sequences

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {"role": "user", "content": "Count from 1 to 10"}
    ],
    "stop": [" 5", "five"],
    "max_tokens": 100
  }' | jq
```

## Use Case Examples

### Programming Examples

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "You are an expert Python programmer."
      },
      {
        "role": "user",
        "content": "Write a Python function to calculate fibonacci numbers"
      }
    ],
    "temperature": 0.2,
    "max_tokens": 300
  }' | jq -r '.choices[0].message.content'
```

### Text Summarization

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "Summarize the following text in one sentence."
      },
      {
        "role": "user",
        "content": "Kubernetes is an open-source container orchestration platform that automates the deployment, scaling, and management of containerized applications. It was originally designed by Google and is now maintained by the Cloud Native Computing Foundation."
      }
    ],
    "temperature": 0.3,
    "max_tokens": 100
  }' | jq -r '.choices[0].message.content'
```

### Question Answering

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "Answer questions based on the given context only."
      },
      {
        "role": "user",
        "content": "Context: OKE is Oracle Kubernetes Engine, a managed Kubernetes service.\n\nQuestion: What is OKE?"
      }
    ],
    "temperature": 0.1,
    "max_tokens": 100
  }' | jq -r '.choices[0].message.content'
```

### Language Translation

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "Translate the following English text to Spanish."
      },
      {
        "role": "user",
        "content": "Hello, how are you today?"
      }
    ],
    "temperature": 0.3,
    "max_tokens": 100
  }' | jq -r '.choices[0].message.content'
```

### Sentiment Analysis

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "Analyze the sentiment of the text as positive, negative, or neutral."
      },
      {
        "role": "user",
        "content": "This product exceeded my expectations! Absolutely love it."
      }
    ],
    "temperature": 0.1,
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'
```

## Streaming Responses

### Server-Sent Events (SSE)

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {"role": "user", "content": "Write a short story about AI"}
    ],
    "stream": true,
    "max_tokens": 200
  }'
```

Response (streaming):
```
data: {"id":"chatcmpl-xxx","choices":[{"delta":{"role":"assistant"},"index":0}]}

data: {"id":"chatcmpl-xxx","choices":[{"delta":{"content":"Once"},"index":0}]}

data: {"id":"chatcmpl-xxx","choices":[{"delta":{"content":" upon"},"index":0}]}

data: {"id":"chatcmpl-xxx","choices":[{"delta":{"content":" a"},"index":0}]}

...

data: [DONE]
```

## Performance Testing

### Latency Test

```bash
#!/bin/bash
for i in {1..5}; do
  echo "Request $i:"
  time curl -s -X POST $NIM_ENDPOINT/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "meta/llama-3.1-8b-instruct",
      "messages": [{"role": "user", "content": "Hi"}],
      "max_tokens": 10
    }' | jq -r '.choices[0].message.content'
  echo ""
done
```

### Throughput Test

```bash
#!/bin/bash
echo "Testing concurrent requests..."
for i in {1..10}; do
  curl -s -X POST $NIM_ENDPOINT/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "meta/llama-3.1-8b-instruct",
      "messages": [{"role": "user", "content": "Hello"}],
      "max_tokens": 10
    }' &
done
wait
echo "All requests completed"
```

### Token Usage Analysis

```bash
curl -s -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {"role": "user", "content": "Explain Kubernetes in detail"}
    ],
    "max_tokens": 500
  }' | jq '.usage'
```

## Python Examples

### Basic Client

```python
import requests
import json

NIM_ENDPOINT = "http://xxx.xxx.xxx.xxx:8000"

def chat_completion(messages, temperature=0.7, max_tokens=150):
    response = requests.post(
        f"{NIM_ENDPOINT}/v1/chat/completions",
        headers={"Content-Type": "application/json"},
        json={
            "model": "meta/llama-3.1-8b-instruct",
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens
        }
    )
    return response.json()

# Example usage
messages = [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is machine learning?"}
]

result = chat_completion(messages)
print(result['choices'][0]['message']['content'])
```

### Streaming Client

```python
import requests
import json

def chat_stream(messages, max_tokens=200):
    response = requests.post(
        f"{NIM_ENDPOINT}/v1/chat/completions",
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream"
        },
        json={
            "model": "meta/llama-3.1-8b-instruct",
            "messages": messages,
            "stream": True,
            "max_tokens": max_tokens
        },
        stream=True
    )
    
    for line in response.iter_lines():
        if line:
            line = line.decode('utf-8')
            if line.startswith('data: '):
                data = line[6:]
                if data != '[DONE]':
                    chunk = json.loads(data)
                    if 'choices' in chunk and len(chunk['choices']) > 0:
                        delta = chunk['choices'][0].get('delta', {})
                        if 'content' in delta:
                            print(delta['content'], end='', flush=True)
    print()

# Example usage
messages = [{"role": "user", "content": "Tell me a joke"}]
chat_stream(messages)
```

### Conversation Manager

```python
class ConversationManager:
    def __init__(self, endpoint, system_prompt=None):
        self.endpoint = endpoint
        self.messages = []
        if system_prompt:
            self.messages.append({"role": "system", "content": system_prompt})
    
    def add_user_message(self, content):
        self.messages.append({"role": "user", "content": content})
    
    def get_response(self, temperature=0.7, max_tokens=150):
        response = requests.post(
            f"{self.endpoint}/v1/chat/completions",
            headers={"Content-Type": "application/json"},
            json={
                "model": "meta/llama-3.1-8b-instruct",
                "messages": self.messages,
                "temperature": temperature,
                "max_tokens": max_tokens
            }
        )
        result = response.json()
        assistant_message = result['choices'][0]['message']['content']
        self.messages.append({"role": "assistant", "content": assistant_message})
        return assistant_message
    
    def clear(self):
        # Keep system prompt if it exists
        if self.messages and self.messages[0]['role'] == 'system':
            self.messages = [self.messages[0]]
        else:
            self.messages = []

# Example usage
conv = ConversationManager(
    NIM_ENDPOINT,
    system_prompt="You are a cloud computing expert."
)

conv.add_user_message("What is OKE?")
print(conv.get_response())

conv.add_user_message("How does it compare to EKS?")
print(conv.get_response())
```

## Error Handling

### Rate Limiting

```bash
# Check rate limit headers
curl -i -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Hi"}],
    "max_tokens": 10
  }' | grep -i "x-ratelimit"
```

### Error Responses

**Invalid model:**

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "invalid-model",
    "messages": [{"role": "user", "content": "Hi"}]
  }'
```

Response:
```json
{
  "error": {
    "message": "Model 'invalid-model' not found",
    "type": "invalid_request_error",
    "code": "model_not_found"
  }
}
```

**Token limit exceeded:**

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Hi"}],
    "max_tokens": 100000
  }'
```

## Monitoring & Metrics

### Get Model Info

```bash
curl $NIM_ENDPOINT/v1/models/meta/llama-3.1-8b-instruct
```

### Performance Metrics

```bash
# If Prometheus metrics are enabled
curl $NIM_ENDPOINT/metrics
```

## Advanced Usage

### Custom Stop Sequences for Structured Output

```bash
curl -X POST $NIM_ENDPOINT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [
      {
        "role": "system",
        "content": "Output JSON only. Format: {\"name\": \"...\", \"age\": ...}"
      },
      {
        "role": "user",
        "content": "Create a person named John, age 30"
      }
    ],
    "stop": ["\n\n", "```"],
    "temperature": 0.1,
    "max_tokens": 100
  }' | jq -r '.choices[0].message.content'
```

### Batch Processing

```bash
#!/bin/bash
# Process multiple inputs from file
while IFS= read -r question; do
  echo "Q: $question"
  curl -s -X POST $NIM_ENDPOINT/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"meta/llama-3.1-8b-instruct\",
      \"messages\": [{\"role\": \"user\", \"content\": \"$question\"}],
      \"max_tokens\": 100
    }" | jq -r '.choices[0].message.content'
  echo ""
done < questions.txt
```

## Troubleshooting API Issues

### Connection Refused

```bash
# Check service status
kubectl get svc nvidia-nim

# Check if pod is ready
kubectl get pods -l app.kubernetes.io/name=nvidia-nim

# Test from within cluster
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://nvidia-nim:8000/v1/health/ready
```

### Slow Responses

```bash
# Check pod logs
kubectl logs -f -l app.kubernetes.io/name=nvidia-nim

# Check resource usage
kubectl top pod -l app.kubernetes.io/name=nvidia-nim

# Describe pod for events
kubectl describe pod -l app.kubernetes.io/name=nvidia-nim
```

### 503 Service Unavailable

Usually means the model is still loading. Check:

```bash
kubectl logs -l app.kubernetes.io/name=nvidia-nim | grep -i "ready\|loading\|error"
```

## Additional Resources

- **OpenAI API Compatibility:** NIM follows OpenAI's API format
- **Meta Llama Docs:** https://llama.meta.com/
- **NVIDIA NIM SDK:** https://docs.nvidia.com/nim/
- **API Reference:** Based on OpenAI Chat Completions API

## Quick Reference

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/health/ready` | GET | Readiness check |
| `/v1/health/live` | GET | Liveness check |
| `/v1/models` | GET | List available models |
| `/v1/chat/completions` | POST | Chat completion |

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `model` | string | required | Model ID |
| `messages` | array | required | Conversation history |
| `temperature` | float | 0.7 | Randomness (0-2) |
| `max_tokens` | int | - | Max tokens to generate |
| `top_p` | float | 1.0 | Nucleus sampling |
| `stream` | boolean | false | Enable streaming |
| `stop` | string/array | null | Stop sequences |

---

**💡 Tip:** Start with `temperature=0.1` for factual responses, `0.7` for balanced, `1.2+` for creative outputs.


