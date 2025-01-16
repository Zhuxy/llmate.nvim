mod models;

use std::thread;

use async_openai::config::OpenAIConfig;
use async_openai::types::{ChatCompletionRequestUserMessageArgs, CreateChatCompletionRequestArgs, FinishReason};
use async_openai::Client;
use nvim_oxi::{ Dictionary, Function, Object};
use nvim_oxi::{libuv::AsyncHandle, schedule};
use tokio::sync::mpsc::{self, UnboundedSender};
use futures::StreamExt;

use models::*;

#[nvim_oxi::plugin]
fn backend() -> Dictionary {
    let chat_stream: Function<(ChatRequest, Function<String, ()>), nvim_oxi::Result<()>> = Function::from_fn(completion_stream);

    let read_prompt_set: Function<String, nvim_oxi::Result<PromptSet>> = Function::from_fn(read_prompt_set);

    let write_prompt_set: Function<(String, PromptSet), nvim_oxi::Result<()>> = Function::from_fn(write_prompt_set);

    let read_config_set: Function<String, nvim_oxi::Result<ConfigSet>> = Function::from_fn(read_config_set);

    Dictionary::from_iter([
        ("chat_stream", Object::from(chat_stream)),
        ("read_prompt_set", Object::from(read_prompt_set)),
        ("write_prompt_set", Object::from(write_prompt_set)),
        ("read_config_set", Object::from(read_config_set)),
    ])
}

fn read_config_set(path: String) -> nvim_oxi::Result<ConfigSet> {
    let config_set = std::fs::read_to_string(path).unwrap();
    let config_set = serde_yml::from_str::<ConfigSet>(config_set.as_str()).unwrap();
    Ok(config_set)
}

fn read_prompt_set(path: String) -> nvim_oxi::Result<PromptSet> {
    let prompt_set = std::fs::read_to_string(path).unwrap();
    let prompt_set = serde_yml::from_str::<PromptSet>(prompt_set.as_str()).unwrap();
    Ok(prompt_set)
}

fn write_prompt_set(arg: (String, PromptSet)) -> nvim_oxi::Result<()> {
    let path = arg.0;
    let prompt_set = arg.1;
    let prompt_set = serde_yml::to_string(&prompt_set).unwrap();
    std::fs::write(path, prompt_set).unwrap();
    Ok(())
}

fn completion_stream(arg: (ChatRequest, Function<String, ()>)) -> nvim_oxi::Result<()> {
    let req = arg.0;
    let callback = arg.1;

    let (sender, mut receiver) = mpsc::unbounded_channel::<String>();

    let handle = AsyncHandle::new(move || {
        let chunk = receiver.blocking_recv().unwrap();
        let cb = callback.clone();
        schedule(move |_| {
            cb.call(chunk).unwrap()
        });
    })?;

    let _ = thread::spawn(move || execute_openai_call(req, handle, sender));

    Ok(())
}


#[tokio::main]
async fn execute_openai_call(req: ChatRequest, handle: AsyncHandle, sender: UnboundedSender<String>) {
   let config = OpenAIConfig::new()
        .with_api_key(req.api_key)
        .with_api_base(req.api_base);


    let client = Client::with_config(config);

    let request = CreateChatCompletionRequestArgs::default()
        .model(req.model)
        .max_tokens(req.max_tokens)
        .messages([ChatCompletionRequestUserMessageArgs::default()
            .content(req.prompt)
            .build().unwrap()
            .into()])
        .build().unwrap();

    let mut stream = client.chat().create_stream(request).await.unwrap();

    while let Some(result) = stream.next().await {
        match result {
            Ok(response) => {
                // BUG: It seems some api responses too quickly, blocking communication
                // between rust and neovim. So a slight delay has been added here.
                tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;

                response.choices.iter().for_each(|chat_choice| {
                    if let Some(reason) = chat_choice.finish_reason {
                        if reason == FinishReason::Stop {
                            sender.send("[[DONE]]".to_string()).unwrap();
                            handle.send().unwrap();
                            return
                        }
                    }
                    if let Some(ref content) = chat_choice.delta.content {
                        sender.send(content.to_string()).unwrap();
                        handle.send().unwrap();
                    }
                });
            }
            Err(err) => {
                sender.send(format!("Error: {err}")).unwrap();
                handle.send().unwrap();
            }
        }
    } 
}
