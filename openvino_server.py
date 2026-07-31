#!/usr/bin/env python3
import sys
import os
import argparse
import queue
import threading
import json
import time
import subprocess
from pathlib import Path

# Try to import dependencies, print helpful error if missing
try:
    from fastapi import FastAPI, Request, HTTPException
    from fastapi.responses import StreamingResponse
    from fastapi.middleware.cors import CORSMiddleware
    import uvicorn
    import anyio
    import openvino_genai as ov_genai
except ImportError as e:
    print(f"Error: Missing dependency: {e}")
    print("Please run: pip install fastapi uvicorn openvino-genai")
    sys.exit(1)

def get_default_model_dir():
    home = Path.home()
    return home / ".cache" / "openvino_models" / "Qwen2.5-Coder-1.5B-Instruct-int4"

def ensure_default_model(model_path: Path):
    if model_path.exists() and any(model_path.glob("*.xml")):
        return True

    print(f"Model not found at {model_path}.")
    print("Automatically exporting Qwen/Qwen2.5-Coder-1.5B-Instruct to INT4 OpenVINO IR format...")
    model_path.parent.mkdir(parents=True, exist_ok=True)
    
    # Run optimum-cli to download and export the model
    cmd = [
        sys.executable, "-m", "optimum.exporters.onnx.cli",  # fallback / direct CLI
    ]
    # Actually, the standard command is 'optimum-cli'
    optimum_cli = Path(sys.executable).parent / "optimum-cli"
    if not optimum_cli.exists():
        optimum_cli = "optimum-cli"
        
    export_cmd = [
        str(optimum_cli), "export", "openvino",
        "--model", "Qwen/Qwen2.5-Coder-1.5B-Instruct",
        "--weight-format", "int4",
        str(model_path)
    ]
    
    print(f"Running command: {' '.join(export_cmd)}")
    try:
        subprocess.run(export_cmd, check=True)
        print("✓ Model successfully downloaded and exported to OpenVINO IR!")
        return True
    except subprocess.CalledProcessError as e:
        print(f"Error exporting model: {e}")
        return False

# Setup FastAPI App
app = FastAPI(title="OpenVINO Local OpenAI-compatible API Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

pipe = None
model_id = ""

class TokenStreamer:
    def __init__(self, q: queue.Queue):
        self.q = q

    def __call__(self, subword: str) -> bool:
        self.q.put(subword)
        return False  # False means continue generation

@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {
                "id": model_id,
                "object": "model",
                "created": int(time.time()),
                "owned_by": "openvino"
            }
        ]
    }

@app.post("/v1/chat/completions")
async def chat_completions(req: Request):
    global pipe, model_id
    if pipe is None:
        raise HTTPException(status_code=500, detail="OpenVINO LLM Pipeline is not initialized.")
        
    try:
        data = await req.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body.")

    messages = data.get("messages", [])
    if not messages:
        raise HTTPException(status_code=400, detail="Messages list cannot be empty.")

    stream = data.get("stream", False)
    temperature = data.get("temperature", 0.7)
    max_tokens = data.get("max_tokens", 1024)

    # Format prompt using the tokenizer's chat template
    try:
        tokenizer = pipe.get_tokenizer()
        prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    except Exception as e:
        # Fallback to simple formatting if apply_chat_template fails
        print(f"Warning: apply_chat_template failed: {e}. Falling back to simple formatting.")
        prompt = ""
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            prompt += f"<|im_start|>{role}\n{content}<|im_end|>\n"
        prompt += "<|im_start|>assistant\n"

    # Build GenerationConfig
    config = ov_genai.GenerationConfig()
    config.max_new_tokens = max_tokens
    config.temperature = temperature
    config.do_sample = temperature > 0.0

    if not stream:
        def generate():
            return pipe.generate(prompt, config)
        response_text = await anyio.to_thread.run_sync(generate)
        
        created_time = int(time.time())
        return {
            "id": f"chatcmpl-{created_time}",
            "object": "chat.completion",
            "created": created_time,
            "model": model_id,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": response_text
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": len(tokenizer.encode(prompt).input_ids) if hasattr(tokenizer, "encode") else 0,
                "completion_tokens": len(tokenizer.encode(response_text).input_ids) if hasattr(tokenizer, "encode") else 0,
                "total_tokens": 0
            }
        }

    else:
        q = queue.Queue()
        streamer_cb = TokenStreamer(q)

        def run_generation():
            try:
                pipe.generate(prompt, config, streamer_cb)
            except Exception as e:
                print(f"Error during generation: {e}")
                q.put(f"[ERROR: {str(e)}]")
            finally:
                q.put(None)  # Signal EOF

        # Run generation in a separate thread
        thread = threading.Thread(target=run_generation)
        thread.start()

        async def event_generator():
            created_time = int(time.time())
            chat_id = f"chatcmpl-{created_time}"
            
            # Send initial role chunk
            initial_chunk = {
                "id": chat_id,
                "object": "chat.completion.chunk",
                "created": created_time,
                "model": model_id,
                "choices": [
                    {
                        "index": 0,
                        "delta": {"role": "assistant"},
                        "finish_reason": None
                    }
                ]
            }
            yield f"data: {json.dumps(initial_chunk)}\n\n"

            while True:
                try:
                    token = await anyio.to_thread.run_sync(q.get)
                except Exception:
                    break

                if token is None:
                    break

                chunk = {
                    "id": chat_id,
                    "object": "chat.completion.chunk",
                    "created": created_time,
                    "model": model_id,
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"content": token},
                            "finish_reason": None
                        }
                    ]
                }
                yield f"data: {json.dumps(chunk)}\n\n"

            final_chunk = {
                "id": chat_id,
                "object": "chat.completion.chunk",
                "created": created_time,
                "model": model_id,
                "choices": [
                    {
                        "index": 0,
                        "delta": {},
                        "finish_reason": "stop"
                    }
                ]
            }
            yield f"data: {json.dumps(final_chunk)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(event_generator(), media_type="text/event-stream")

def main():
    global pipe, model_id
    parser = argparse.ArgumentParser(description="Start an OpenAI-compatible API server using OpenVINO GenAI")
    parser.add_argument("--model-path", "-m", type=str, default=os.getenv("OPENVINO_MODEL_PATH", ""),
                        help="Path to directory containing OpenVINO IR model (.xml)")
    parser.add_argument("--device", "-d", type=str, default=os.getenv("OPENVINO_DEVICE", "GPU"),
                        help="Target device for inference (CPU, GPU, NPU)")
    parser.add_argument("--host", type=str, default=os.getenv("OPENVINO_HOST", "127.0.0.1"),
                        help="Host to bind the server to")
    parser.add_argument("--port", type=int, default=int(os.getenv("OPENVINO_PORT", 8000)),
                        help="Port to bind the server to")
    args = parser.parse_args()

    # Determine model path
    model_path_str = args.model_path
    if not model_path_str:
        default_dir = get_default_model_dir()
        print(f"No model path specified. Checking for default model at: {default_dir}")
        if ensure_default_model(default_dir):
            model_path_str = str(default_dir)
        else:
            print("Failed to secure or download default model. Please specify --model-path.")
            sys.exit(1)

    model_path = Path(model_path_str).resolve()
    if not model_path.exists():
        print(f"Error: Model path does not exist: {model_path}")
        sys.exit(1)

    model_id = model_path.name
    print(f"Loading OpenVINO model from: {model_path}")
    print(f"Target Device: {args.device}")
    
    try:
        pipe = ov_genai.LLMPipeline(str(model_path), args.device)
        print("✓ OpenVINO GenAI Pipeline successfully initialized!")
    except Exception as e:
        print(f"Error initializing OpenVINO GenAI pipeline: {e}")
        sys.exit(1)

    print(f"Starting API server at http://{args.host}:{args.port}")
    uvicorn.run(app, host=args.host, port=args.port)

if __name__ == "__main__":
    main()
